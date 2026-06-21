# Media Canvas

여러 동영상 · 이미지 · GIF 를 한 화면에서 동시에 재생하고, 자유 배치 + 레이어(depth) + 개별 음량/재생 제어 + 설정 + 파일 추출을 지원하는 Flutter 앱입니다. **Windows / Android** 양쪽에서 동작합니다.

## 핵심 기능

- **동시 재생**: 비디오마다 독립된 `media_kit` (`libmpv`) 플레이어. 여러 FHD 동시 재생을 GPU 가속으로 처리.
- **개별 제어**: 각 비디오에 재생/일시정지, 음소거, 볼륨 슬라이더. 모든 소리를 동시에 켤 수 있음.
- **전역 제어**: 모두 재생 / 모두 정지 / 모두 음소거 / 모두 음소거 해제.
- **자유 배치**: 드래그로 이동, 우하단 핸들로 크기 조정, 회전·투명도 슬라이더.
- **Stack 레이어(depth)**: 맨 앞으로 / 앞으로 / 뒤로 / 맨 뒤로 — 비디오·이미지·GIF 를 겹쳐 배치.
- **이미지 · GIF**: 로컬 파일과 URL 모두 지원 (GIF 자동 재생).
- **모든 동영상 링크 지원**: 유튜브뿐 아니라 임의의 동영상 페이지/링크. URL 을 넣으면 페이지 HTML 에서 동영상 스트림을 추출해 재생 — 페이지에 동영상이 하나면 그것을 자동으로 재생. (`<video>`/`<source>`, OG/Twitter 메타, JSON-LD, 인라인 스크립트의 m3u8/mp4, iframe 플레이어 1단계 추적)
- **광고 자동 차단**:
  - *페이지 광고*: 웹뷰/임베드 대신 직접 스트림만 재생하므로 프리롤·오버레이·배너 등 페이지 광고 머신이 아예 로드되지 않음. 광고/트래커 호스트 URL 은 후보에서 제외.
  - *서버 삽입 광고(SSAI)*: HLS 재생목록의 SCTE-35 마커(`#EXT-X-CUE-OUT`/`CUE-IN`, `DATERANGE`)를 읽어 광고 세그먼트를 제거한 재생목록으로 재생 → 광고 구간 자동 스킵, 본편만 이어서 재생.
- **URL 영상 다운로드**: URL 로 등록한 영상을 **길게 누르면** 화질을 고르고 저장 위치를 정해 진행률·취소가 있는 다운로드 시작.
  - **화질 선택**: 유튜브(muxed 화질), HLS 마스터(variant 해상도), DASH(representation) 의 가용 화질을 목록으로 보여주고 선택. 단일 화질 소스(일반 mp4)는 바로 진행.
  - **파일명에 화질·앱 버전 표기**: 저장 파일명에 선택한 화질과 앱 버전이 들어갑니다 (예: `제목_720p_v1.0.1.mp4`).
  - *progressive* (mp4/webm 등, 유튜브 포함): 직접 스트리밍 저장.
  - *adaptive* (HLS `.m3u8` / DASH `.mpd`): 세그먼트를 받아 하나로 합쳐 저장(HLS TS→`.ts`, fMP4/DASH→`.mp4`). AES-128 암호화 HLS 는 자동 복호화, SSAI 광고는 제거 후 저장.
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
flutter run -d windows     # 윈도우
flutter run -d <device-id> # 안드로이드 (flutter devices 로 id 확인)
```

> 첫 빌드 시 `media_kit_libs_video` 가 libmpv 바이너리를 자동으로 받아옵니다. 별도 시스템 설치 불필요.

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
- 이 환경에서는 Flutter 컴파일·실행을 할 수 없어 빌드 검증은 못 했습니다. 처음 `flutter run` 시 패키지 버전 충돌이 나면 `flutter pub upgrade` 로 맞추세요.

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
│   ├── media_url_resolver.dart     # 임의 URL → 직접 스트림 추출 (+ 페이지 광고 차단)
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
