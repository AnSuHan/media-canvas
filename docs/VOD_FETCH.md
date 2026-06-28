# 동영상 가져오기 — 웹페이지에서 스트림 추출 · 재생 · 다운로드 · URL 라이브러리

이 문서는 **"동영상 가져오기"** 기능과, Cloudflare 로 보호된 VOD 사이트
(예: `https://<vod-site>/vod/<id>`)에서 동영상을 **앱 내부에서 재생·다운로드**
하기 위한 구조·원리·사용법·테스트 방법을 정리한다.

---

## 1. 무엇을 하나

- 동영상 페이지 주소를 붙여넣으면, 페이지 안에 박힌 **실제 스트림(m3u8/mp4)** 을
  뽑아낸다. (퍼블리셔의 광고 HTML/JS 를 웹뷰로 띄우지 않으므로 광고도 안 탄다.)
- 뽑아낸 영상을 **앱 보드에서 바로 재생**하고, **파일로 다운로드**한다.
- 주소를 **URL 라이브러리**에 저장해 두고 나중에 다시 불러온다.
- 일부 사이트의 CDN 은 일반 클라이언트를 차단하는데(아래 2절), 번들된 **yt-dlp**
  의 브라우저 위장으로 이를 우회해 재생·다운로드한다. VPN 으로만 접근되는
  사이트도, 앱이 사용자의 네트워크(=VPN)를 그대로 타므로 동작한다.

진입점:
- 데스크톱 상단 툴바 🔭 **"동영상 가져오기"** 버튼
- 모바일: 추가(＋) 메뉴 → **"동영상 가져오기"**
- 기존 **Add URL** 버튼으로 보호 사이트 링크를 추가해도 동일하게 재생/다운로드된다.

---

## 2. 핵심 원리 — 왜 단순 재생이 안 되는가 (Cloudflare TLS 차단)

이런 사이트의 **페이지 호스트**는 일반 요청으로도 열리는 경우가 많다(HTTP 200).
하지만 영상 **스트림 호스트(별도 CDN)** 는 Cloudflare 가 **TLS 지문(JA3/JA4)** 으로
막는다.

검증 결과(실측):

| 클라이언트 | Referer 등 헤더 | 결과 |
|---|---|---|
| 일반 curl | 완비 | **403 (Cloudflare 차단)** |
| Python urllib (OpenSSL TLS) | 완비 | **403** |
| libmpv / Dart `http` | 완비 | **403 (TLS 지문 불일치)** |
| **curl_cffi (Chrome TLS 위장)** | 완비 | **200 OK** |

즉 **헤더가 아니라 TLS 핸드셰이크 지문**으로 막는다. 따라서:

- libmpv(media_kit)는 브라우저 TLS 를 흉내 낼 수 없어 **직접 재생 불가**.
- Dart `http` 기반 다운로더도 동일하게 **403**.
- 번들된 **yt-dlp 는 curl_cffi 를 포함**하므로 `--impersonate chrome` 으로
  브라우저 TLS 를 재현 → 통과한다. 여기에 **`Referer: <페이지 URL>`** 도 필요
  (핫링크 보호).

---

## 3. 동작 구조

```
[페이지 URL]
   │  resolveVideoSource(): 페이지 HTML 가져와 og:title/og:image + 스트림(m3u8) 추출
   │                         + 스트림에 가벼운 probe → 403 이면 "위장 필요"로 판정
   ▼
[VideoSource] = { pageUrl, streamUrl, referer, needsImpersonation, title, thumbnail }
   │
   ├── 재생(위장 필요 X) ── libmpv 가 streamUrl 직접 재생 (+ HLS 광고 필터)
   │
   ├── 재생(위장 필요 O) ── 로컬 프록시 경유:
   │       libmpv ──http──▶ 127.0.0.1:PORT ──spawn──▶ yt-dlp --impersonate chrome
   │                                                     --add-header Referer:<page>
   │                                                     --hls-use-mpegts -o -
   │                                                        │ (browser TLS)
   │                                                        ▼
   │                                                Cloudflare 보호 CDN
   │       └ yt-dlp 가 MPEG-TS 바이트를 stdout 으로 흘리고, 프록시가 그대로
   │         libmpv 에 localhost 로 전달(중간에 Cloudflare 없음). TS 는 받는 즉시 재생.
   │
   └── 다운로드(위장 필요 O) ── yt-dlp --impersonate chrome --add-header Referer:<page>
                                  -f best -o <savePath>  (HLS 조각을 받아 파일로 저장)
```

판정은 자동이다. `streamNeedsImpersonation()` 이 **Dart `http` 로 1~2바이트 range
probe** 를 보내 `403`(또는 Cloudflare 챌린지)이면 위장 경로로 라우팅한다. 200/206
이면 기존 빠른 경로를 그대로 쓴다. **YouTube** 는 절대 이 방식으로 막히지 않으므로
probe 를 건너뛴다(공통 케이스 성능 보존).

### 재생 신뢰성 — 프록시 시작 지연 처리 (중요)

위장 프록시 재생은 **두 가지 조건이 모두** 갖춰져야 libmpv 가 연다. 둘 중 하나라도
빠지면 libmpv 가 `Failed to open` 으로 즉시 실패한다(증상: 보드 타일이 계속 로딩만
되다 에러). 실제 단말 재현으로 확인한 사항:

1. **프록시는 HTTP 응답 헤더를 즉시 flush 한다** (`StreamProxy._handle` 의
   `response.flush()`). yt-dlp 가 첫 바이트를 내보내기까지 수 초(브라우저 TLS
   핸드셰이크 → m3u8 → 첫 세그먼트)가 걸리는데, 그 전에 `200 OK` 헤더를 먼저
   보내 libmpv 가 "연결은 살아 있다"고 인지하게 한다.
2. **libmpv `network-timeout` 을 늘린다** (`BoardController._spinUpPlayer` 에서
   `setProperty('network-timeout','60')`). 기본 타임아웃은 yt-dlp 워밍업보다 짧아
   첫 데이터 도착 전에 포기한다. 로컬 파일·일반 링크에는 무해하다.

검증: 실제 보드 파이프라인(`Player`+`VideoController`+`Video` 위젯)으로 보호 VOD 를
열어 `720x1562` 영상이 디코드되고 재생 위치가 정상 증가함을 확인.

---

## 4. 관련 코드

| 파일 | 역할 |
|---|---|
| `lib/widgets/source_page.dart` | "동영상 가져오기" 화면(가져오기·재생·다운로드·라이브러리 UI) |
| `lib/services/page_video_resolver.dart` | 페이지 → `VideoSource`(스트림·제목·썸네일·위장 필요 여부) |
| `lib/services/stream_proxy.dart` | 로컬 HTTP 프록시(libmpv ⇄ yt-dlp 위장 스트림) |
| `lib/services/link_store.dart` | URL 라이브러리 저장(`links.json`) |
| `lib/models/video_source.dart` | `VideoSource`, `SavedLink` 모델 |
| `lib/services/ytdlp.dart` | `ytDlpStreamMpegTs()`(재생용 stdout 스트림), `ytDlpDownload(impersonate, referer)` |
| `lib/services/media_url_resolver.dart` | 스트림/메타 추출 헬퍼, `streamNeedsImpersonation()` probe |
| `lib/services/board_controller.dart` | 재생(`_resolvePlayable`)·다운로드(`listDownloadOptions`) 위장 경로 자동 라우팅 |
| `lib/services/download/download_option.dart` | `impersonate`, `referer` 필드 |

저장 위치: 보드 레이아웃과 같은 앱 문서 폴더(`media_canvas/`) 안 `links.json`.

---

## 4.5 진단 로그 (재생/다운로드가 안 될 때)

앱에 **진단 로그 뷰어**가 있다. "동영상 가져오기" 화면 우상단 🐞 아이콘, 또는
설정 → 정보 → "진단 로그 보기" 로 연다. 각 단계가 시간순으로 기록된다:

- `app` — 시작 시 OS·앱 버전·**yt-dlp 사용 가능 여부/경로** (보호 사이트 실패의 1순위 원인).
- `fetch` — 페이지 가져오기 결과(스트림 URL·보호 여부·제목).
- `probe` — 보호 판별 HTTP status(403 이면 위장 경로).
- `resolve` — 재생 해석 결과와 위장 프록시 경유 여부.
- `proxy` — 프록시 등록/요청, yt-dlp 스폰(pid), 헤더 전송, 전송량, 종료 code.
- `yt-dlp` — yt-dlp 자체 경고/오류(stderr).
- `libmpv` — libmpv 의 경고/오류(예: `Failed to open …`).
- `download` — 다운로드 시작/완료/실패(code·stderr).

로그는 우상단 복사 버튼으로 통째로 복사할 수 있어 버그 리포트에 붙이기 좋다.
대표 증상별 단서: `app` 에 "yt-dlp 없음" → 번들 누락(빌드 전 `fetch_ytdlp.ps1`),
`libmpv … Failed to open` → 프록시 시작 지연(4.x 의 헤더 flush + network-timeout),
`download 실패 code=…` → yt-dlp stderr 에 원인.

## 5. 사용법

1. 앱 실행: `flutter run -d windows`
2. 상단 🔭 **동영상 가져오기** → 주소 입력(예: VOD 페이지) → **가져오기**.
3. 미리보기에 제목/썸네일과 (보호 스트림이면) "브라우저 위장으로 재생·다운로드"
   배지가 표시된다.
4. **앱에서 재생** → 보드에 추가되어 바로 재생 / **다운로드** → 저장 위치 선택 /
   **라이브러리에 저장** → 아래 목록에 추가.
5. 저장한 링크는 탭하면 다시 불러오고, 휴지통으로 삭제.

> 사이트 접근(지역 제한)은 **사용자 VPN/네트워크**가 처리한다. 앱은 그 네트워크를
> 그대로 사용하므로, 브라우저에서 열리는 사이트면 앱에서도 동작한다.

전제: `assets/bin/yt-dlp.exe` 가 번들되어 있어야 한다(`tool/fetch_ytdlp.ps1` 로 받음).
릴리스 빌드 시 `data/flutter_assets/assets/bin/yt-dlp.exe` 로 함께 패키징된다.

---

## 6. 테스트

### 오프라인 단위테스트 (네트워크 불필요, 항상 실행)
```
flutter test test/page_video_resolver_test.dart    # 스트림/제목/썸네일 추출, 403→위장 판정
flutter test test/link_store_test.dart             # URL 라이브러리 저장/정렬/중복제거/삭제
flutter test test/stream_proxy_test.dart           # yt-dlp 없을 때 안전 동작, 루프백 URL 형식
```

### 라이브 종단 테스트 (실제 사이트·yt-dlp·네트워크 필요, 기본 skip)
**확인할 페이지 주소를 직접 넘겨** 실행한다(URL 은 코드에 박혀 있지 않다). 해당
링크에서 **① 보호 스트림 판별 → ② 프록시가 유효한 MPEG-TS(0x47) 재생 →
③ 실제 영상 바이트 다운로드** 까지 증명한다.
```
flutter test test/live_protected_vod_test.dart ^
  --dart-define=LIVE=true --dart-define=VOD_URL=https://<vod-site>/vod/<id>
```
`LIVE` 와 `VOD_URL` 이 모두 주어졌을 때만 실행되고, 없으면 자동 skip 된다.

#### 통과 시 출력 예시
```
resolves the VOD page to a protected stream
  stream: https://<cdn-host>/<id>/master.m3u8
PLAY: the local proxy serves a real MPEG-TS stream
  proxy: http://127.0.0.1:PORT/s/1 → first 65536 bytes ok (TS sync 0x47)
DOWNLOAD: yt-dlp impersonate+referer writes real bytes
  downloaded <N> bytes
All tests passed!
```
오프라인 스위트(약 100개)는 항상 통과, 회귀 없음. `flutter build windows --release` 성공.

---

## 7. 알려진 한계 / 주의

- **임퍼소네이트 재생은 선형 스트림**: 프록시가 yt-dlp stdout 을 그대로 흘리므로
  버퍼 범위를 벗어난 뒤로 가는 탐색(seek back)은 제한적이다. 일반 재생/앞으로
  진행은 정상.
- 보호 스트림의 화질 목록은 현재 단일 "원본(best)" 1개로 제공한다(필요 시 yt-dlp
  변형 나열로 확장 가능).
- 스트림 ID(URL 경로의 해시)는 재생 때마다 페이지에서 다시 추출하므로 만료돼도
  동작한다.
- yt-dlp 가 없으면(예: 테스트 러너) 위장 경로는 자동으로 비활성화되고 일반 경로로
  안전하게 폴백한다.
- 합법적 콘텐츠를 사용자가 접근 권한이 있는 범위에서 재생/저장하는 용도다.
```
