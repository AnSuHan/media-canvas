# Media Canvas

여러 동영상 · 이미지 · GIF 를 한 화면에서 동시에 재생하고, 자유 배치 + 레이어(depth) + 개별 음량/재생 제어 + 설정 + 파일 추출을 지원하는 Flutter 앱입니다. **Windows / Android** 양쪽에서 동작합니다.

## 핵심 기능

- **동시 재생**: 비디오마다 독립된 `media_kit` (`libmpv`) 플레이어. 여러 FHD 동시 재생을 GPU 가속으로 처리.
- **개별 제어**: 각 비디오에 재생/일시정지, 음소거, 볼륨 슬라이더. 모든 소리를 동시에 켤 수 있음.
- **전역 제어**: 모두 재생 / 모두 정지 / 모두 음소거 / 모두 음소거 해제.
- **자유 배치**: 드래그로 이동, 우하단 핸들로 크기 조정, 회전·투명도 슬라이더.
- **Stack 레이어(depth)**: 맨 앞으로 / 앞으로 / 뒤로 / 맨 뒤로 — 비디오·이미지·GIF 를 겹쳐 배치.
- **이미지 · GIF**: 로컬 파일과 URL 모두 지원 (GIF 자동 재생).
- **어떤 URL 이든 동작 (자동 종류 판별)**: URL 을 넣으면 그 링크가 실제로 **영상/이미지/GIF** 중 무엇인지 자동으로 판별해 알맞은 화면으로 띄웁니다 — 확장자, 서버의 `Content-Type`, 페이지 스크래핑으로 결정. 이미지/일반 페이지를 영상 엔진에 잘못 넘겨 "unsupported format" 이 뜨던 문제 제거. 영상이 없는 페이지는 미리보기 이미지(og:image)로 폴백, 실패해도 거친 엔진 오류 대신 친근한 한국어 안내를 표시.
- **모든 동영상 링크 지원 (yt-dlp 내장)**: 유튜브·직접 링크(mp4/webm…)·HLS/DASH 스트림은 물론, **인터넷에 배포된 사실상 모든 동영상 링크**를 재생·다운로드합니다.
  - *빌트인 추출*: 페이지 HTML 에서 스트림 직접 추출 (`<video>`/`<source>`, OG/Twitter 메타, JSON-LD, 인라인 m3u8/mp4, iframe 플레이어 1단계). 자바스크립트가 필요 없는 일반 사이트는 이 빠른 경로로 처리.
  - *yt-dlp 폴백*: 빌트인이 닿지 못하는 자바스크립트 기반 사이트(X/트위터, TikTok, 페이스북, Vimeo, 트위치 VOD 등 **약 1800개 사이트**)는 번들된 **yt-dlp** 로 직접 스트림을 추출해 재생·다운로드. 사이트별 코드를 따로 두지 않고 yt-dlp 가 지원하는 범위를 그대로 사용하므로, yt-dlp 만 갱신하면 지원 사이트가 자동으로 넓어집니다. *(Windows 전용 — Android 는 빌트인 추출까지 동작)*
- **동영상 가져오기 페이지 + URL 라이브러리**: 상단 🔭 **"동영상 가져오기"** 화면에서 동영상 페이지 주소를 붙여넣으면 제목·썸네일과 함께 스트림을 추출해 **앱에서 재생 / 다운로드 / 라이브러리에 저장**합니다. 저장한 링크는 목록에서 다시 불러오거나 삭제할 수 있습니다. **Cloudflare 가 TLS 지문으로 막는 VOD 사이트**(libmpv·Dart `http`·일반 curl 은 헤더를 맞춰도 403)도, 번들된 **yt-dlp 의 브라우저 위장(`--impersonate`)** 을 로컬 프록시로 libmpv 에 연결해 **재생**하고, 같은 위장으로 **다운로드**합니다. VPN 으로만 열리는 사이트는 앱이 사용자 네트워크(VPN)를 그대로 타므로 동작합니다. yt-dlp 가 없으면 시작 스플래시에서 자동으로 받아 준비합니다. **⚠️ 보호 사이트의 안정적 재생·다운로드는 Windows(exe) 전용입니다 — Android 는 WebView 로 시도하지만 사이트에 따라 재생되지 않을 수 있습니다.** → 자세한 원리·플랫폼별 동작·테스트: **[docs/VOD_FETCH.md](docs/VOD_FETCH.md)**
- **앱 내 버전 확인**: 설정 화면 맨 아래 **정보** 섹션에서 현재 앱 버전을 표시합니다.
- **Instagram 게시물 전체 펼치기**: 인스타그램 게시물/릴스 링크를 넣으면 그 게시물의 **모든 사진·영상(캐러셀 포함)** 을 한 번에 보드에 올립니다. (공개 게시물 대상, 비공개/로그인 필요 게시물은 불러올 수 없을 수 있음)
- **광고 자동 차단**:
  - *페이지 광고*: 웹뷰/임베드 대신 직접 스트림만 재생하므로 프리롤·오버레이·배너 등 페이지 광고 머신이 아예 로드되지 않음. 광고/트래커 호스트 URL 은 후보에서 제외.
  - *서버 삽입 광고(SSAI)*: HLS 재생목록의 SCTE-35 마커(`#EXT-X-CUE-OUT`/`CUE-IN`, `DATERANGE`)를 읽어 광고 세그먼트를 제거한 재생목록으로 재생 → 광고 구간 자동 스킵, 본편만 이어서 재생.
  - *yt-dlp 경유 링크*: yt-dlp 는 광고 크리에이티브가 아니라 **본편 콘텐츠 스트림**을 추출하므로, 플레이어가 끼워 넣는 프리롤/오버레이 광고는 애초에 들어오지 않습니다(앱의 "직접 스트림 = 광고 차단" 원칙과 동일). 단, 영상 내부에 박힌 스폰서 구간 제거(SponsorBlock)는 ffmpeg 가 필요해 기본 비활성화입니다.
- **URL 영상 다운로드**: URL 로 등록한 영상을 **길게 누르면** 화질을 고르고 저장 위치를 정해 진행률·취소가 있는 다운로드 시작.
  - **화질 선택**: 유튜브(muxed 화질), HLS 마스터(variant 해상도), DASH(representation) 의 가용 화질을 목록으로 보여주고 선택. 단일 화질 소스(일반 mp4)는 바로 진행.
  - **파일명에 화질·앱 버전 표기**: 저장 파일명에 선택한 화질과 앱 버전이 들어갑니다 (예: `제목_720p_v1.0.1.mp4`).
  - *progressive* (mp4/webm 등, 유튜브 포함): 직접 스트리밍 저장.
  - *adaptive* (HLS `.m3u8` / DASH `.mpd`): 세그먼트를 받아 하나로 합쳐 저장(HLS TS→`.ts`, fMP4/DASH→`.mp4`). AES-128 암호화 HLS 는 자동 복호화, SSAI 광고는 제거 후 저장.
  - *yt-dlp 지원 사이트* (X/TikTok/Vimeo 등): 번들된 yt-dlp 가 가용 화질을 나열하고 다운로드를 수행(취소 시 프로세스 종료). ffmpeg 없이 받을 수 있도록 **단일 파일(muxed) 포맷**을 우선 선택.
- **설정 화면**: 새 미디어 기본값(볼륨·음소거·반복·재생), 캔버스 배경(점/격자/단색), 그리드 스냅, 동작 옵션.
- **파일 추출/가져오기**:
  - 보드를 `.board.json` 파일로 내보내기 → 다른 기기에서 다시 열기.
  - 보드를 **PNG 이미지**로 캡처해 저장.
  - `.board.json` 가져오기.
- **내부 저장/불러오기**: 보드를 앱 내부에 이름으로 저장하고 다시 로드.

## 실행 방법

```bash
flutter --version          # 3.3 이상 확인
flutter pub get
pwsh tool/fetch_ytdlp.ps1  # (Windows) yt-dlp.exe 를 assets/bin/ 으로 받기 — 번들용
flutter run -d windows     # 윈도우
flutter run -d <device-id> # 안드로이드 (flutter devices 로 id 확인)
```

> 첫 빌드 시 `media_kit_libs_video` 가 libmpv 바이너리를 자동으로 받아옵니다. 별도 시스템 설치 불필요.
>
> **yt-dlp 번들**: `assets/bin/yt-dlp.exe` 는 용량(약 18MB) 때문에 git 에 포함하지 않습니다. Windows 빌드 전에 `tool/fetch_ytdlp.ps1` 로 한 번 받아 두면, 빌드 시 앱 에셋으로 함께 패키징되어 앱 옆 경로에서 자동 실행됩니다. 받지 않아도 빌드는 되며, 이 경우 yt-dlp 폴백만 비활성화되고 빌트인 추출은 그대로 동작합니다.

### 릴리스용 단일 exe 만들기 (Windows)

배포 자산으로 **단일 실행 파일**(`MediaCanvas-v<버전>.exe`)을 만듭니다. 사용자는 이 파일 하나만 받아 더블클릭하면, 임시 폴더에 풀린 뒤 앱이 바로 실행됩니다(설치·압축 해제 불필요). 7-Zip SFX 방식이라 7-Zip 설치가 필요합니다.

```powershell
pwsh tool/fetch_ytdlp.ps1            # yt-dlp.exe 받아 번들 준비
flutter build windows --release      # 앱 빌드
pwsh tool/package_windows.ps1        # → release_assets/MediaCanvas-v<버전>.exe
```

`package_windows.ps1` 은 pubspec 의 버전을 읽어 Release 폴더를 SFX exe 로 묶고, 무결성·루트의 `media_canvas.exe` 존재를 검증합니다. 버전을 직접 지정하려면 `-Version 1.0.4` 처럼 넘깁니다.

> **내려받아 바로 실행**: [GitHub Releases](https://github.com/AnSuHan/media-canvas/releases) 에서 `MediaCanvas-v<버전>.exe` 하나만 받아 더블클릭하면 됩니다. 설치·압축 해제·런타임 설치가 필요 없습니다(임시 폴더에 풀려 실행). 백신이 "알 수 없는 앱" 경고를 띄우면 "추가 정보 → 실행" 으로 진행하세요.

## 플랫폼 설정

### Android — `android/app/src/main/AndroidManifest.xml`
네트워크 URL 재생 및 파일 저장에 필요:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

`http://` (비 HTTPS) URL 도 쓰려면 `<application>` 에 `android:usesCleartextTraffic="true"` 추가. `minSdkVersion` 21 이상 권장.

`wakelock_plus` 빌드 시 NDK 버전 관련 경고가 뜨면, `android/app/build.gradle` 의 `android { }` 안에 메시지가 알려주는 버전으로 `ndkVersion flutter.ndkVersion` 을 추가하세요.

### Windows
별도 설정 불필요. 첫 빌드는 Visual Studio "Desktop development with C++" 워크로드 필요.

## 남은 참고사항

- 비디오 개수가 많아지면 기기의 하드웨어 디코더 한계(보통 5~16개)에 따라 끊길 수 있습니다.
- PNG 합성 시 영상은 "현재 프레임"이 캡처됩니다. 재생 중이라면 캡처 시점의 화면이 담깁니다.
- 다운로드 한계: DASH 에서 오디오·비디오가 **별도 트랙**으로 분리된 경우 ffmpeg 없이 한 컨테이너로 합칠 수 없어, 최고 화질 **비디오 트랙만**(무음) 저장됩니다. 매니페스트를 계속 갱신하는 라이브 SSAI 는 한 번의 재작성으로 추적하지 않습니다.
- yt-dlp 경유 다운로드도 같은 이유로 **단일 파일(muxed) 포맷**을 우선합니다. 따라서 일부 사이트의 4K 처럼 영상·음성이 분리만 제공되는 최상위 화질은 (ffmpeg 미번들로) 받지 못하고, 음성이 포함된 가장 높은 단일 화질을 받습니다.
- yt-dlp 폴백은 **Windows 전용**입니다(Windows 바이너리만 번들). Android 는 빌트인 추출까지 동작합니다.

## 파일 추출/가져오기 (네이티브 저장 대화상자)

- **보드 → `.board.json`**: 원하는 위치로 내보내 다른 기기에서 다시 열기
- **보드 → PNG 이미지**: 캔버스를 그대로 캡처해 저장. **동영상 프레임도 포함됩니다** — 각 영상의 현재 프레임을 `player.screenshot()`로 받아 위치·크기·회전·투명도 그대로 합성합니다.
- **`.board.json` 가져오기**: 외부 파일을 불러와 보드 교체
- 데스크톱은 공유 아이콘, 모바일은 ⋮ 메뉴에 있습니다. 한글 보드 이름도 UTF-8로 안전하게 처리합니다.

## 화면 켜둠 (실제 동작)

설정의 "화면 켜둠"을 켜면 `wakelock_plus`로 실제 화면 꺼짐을 막습니다(Windows·Android 모두, 별도 권한 불필요). 설정을 끄거나 앱을 닫으면 자동 해제됩니다.

## 구조

```
lib/
├── main.dart                       # 앱 진입, 캔버스, 반응형 툴바, 추출/설정 연결
├── theme.dart                      # "편집 콘솔" 팔레트 + ThemeData
├── models/
│   ├── media_item.dart             # MediaItem + BoardState (JSON)
│   └── app_settings.dart           # AppSettings (JSON)
├── services/
│   ├── board_controller.dart       # 상태·플레이어·z-order·전역제어·설정·wakelock
│   ├── board_exporter.dart         # PNG 합성 (영상 프레임 포함)
│   ├── layout_store.dart           # 저장/불러오기 + 파일 추출/가져오기 + 설정 영속화
│   ├── media_url_resolver.dart     # 임의 URL → 종류 판별 + 직접 스트림 추출 (+ 페이지 광고 차단, yt-dlp 폴백)
│   ├── ytdlp.dart                  # 번들 yt-dlp 구동: 스트림 추출·화질 나열·다운로드 (1800+ 사이트)
│   ├── instagram_resolver.dart     # 인스타 게시물 → 모든 사진·영상 추출
│   ├── hls_ad_filter.dart          # HLS SSAI 광고 세그먼트 제거 (재생·다운로드 공용)
│   └── download/                   # ⬇ 동영상 다운로드 모듈 (추후 패키지 분리 가능)
│       ├── download.dart           #   배럴(공개 API) — 이 파일만 import
│       ├── video_downloader.dart   #   VideoDownloader 파사드(단일 진입점)
│       ├── download_option.dart    #   DownloadOption(화질 선택 모델)
│       ├── progressive_downloader.dart  # mp4/webm 등 단일 파일 스트리밍 저장
│       └── adaptive_downloader.dart     # HLS/DASH 화질 나열·세그먼트 다운로드·복호화·합치기
└── widgets/
    ├── board_item_widget.dart      # 드래그/리사이즈 가능한 개별 미디어 위젯 (길게눌러 다운로드)
    └── settings_page.dart          # 설정 화면
```

### 다운로드 모듈 (`lib/services/download/`)

동영상 다운로드 로직은 **자체 완결형 모듈**로 분리되어 있어 추후 별도 패키지로 떼어낼 수 있습니다.

- **공개 API**: `download.dart` 배럴 하나만 import 하고, [`VideoDownloader`] 파사드를 사용합니다. UI 는 progressive/adaptive 구분이나 하위 함수를 직접 알 필요가 없습니다.
  ```dart
  const dl = VideoDownloader();
  if (dl.canDownload(url)) {
    final path = await dl.download(url, savePath,
        client: client,                       // client.close() 로 취소
        onProgress: (f) => print('${(f ?? 0) * 100}%'));
  }
  ```
- **경계(의존성)**: 외부 `http`·`pointycastle`·`xml` 와, HLS 매니페스트 헬퍼인 `../hls_ad_filter.dart` 에만 의존합니다. 앱 위젯·컨트롤러·모델을 전혀 모릅니다(URL·파일경로만 주고받음). → 패키지로 추출 시 `hls_ad_filter.dart` 만 함께 옮기면 됩니다.

## 사용 팁

- 아이템을 **탭** 하면 선택. 선택 시에만 제목 바·컨트롤·리사이즈 핸들 표시.
- 빈 공간 탭 → 선택 해제.
- 데스크톱(≥720px): 상단 풀바 + 하단 depth 도크. 모바일: 상단바 축약 + 레이어 바텀시트.
- 추출/가져오기는 공유 아이콘(데스크톱) 또는 ⋮ 메뉴(모바일)에서.
