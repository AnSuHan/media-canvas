# Media Canvas

여러 동영상 · 이미지 · GIF 를 한 화면에서 동시에 재생하고, 자유 배치 + 레이어(depth) + 개별 음량/재생 제어 + 설정 + 파일 추출을 지원하는 Flutter 앱입니다. **Windows / Android** 양쪽에서 동작합니다.

## 핵심 기능

- **동시 재생**: 비디오마다 독립된 `media_kit` (`libmpv`) 플레이어. 여러 FHD 동시 재생을 GPU 가속으로 처리.
- **개별 제어**: 각 비디오에 재생/일시정지, 음소거, 볼륨 슬라이더. 모든 소리를 동시에 켤 수 있음.
- **전역 제어**: 모두 재생 / 모두 정지 / 모두 음소거 / 모두 음소거 해제.
- **자유 배치**: 드래그로 이동, 우하단 핸들로 크기 조정, 회전·투명도 슬라이더.
- **Stack 레이어(depth)**: 맨 앞으로 / 앞으로 / 뒤로 / 맨 뒤로 — 비디오·이미지·GIF 를 겹쳐 배치.
- **이미지 · GIF**: 로컬 파일과 URL 모두 지원 (GIF 자동 재생).
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
│   └── layout_store.dart           # 저장/불러오기 + 파일 추출/가져오기 + 설정 영속화
└── widgets/
    ├── board_item_widget.dart      # 드래그/리사이즈 가능한 개별 미디어 위젯
    └── settings_page.dart          # 설정 화면
```

## 사용 팁

- 아이템을 **탭** 하면 선택. 선택 시에만 제목 바·컨트롤·리사이즈 핸들 표시.
- 빈 공간 탭 → 선택 해제.
- 데스크톱(≥720px): 상단 풀바 + 하단 depth 도크. 모바일: 상단바 축약 + 레이어 바텀시트.
- 추출/가져오기는 공유 아이콘(데스크톱) 또는 ⋮ 메뉴(모바일)에서.
