# videojoin (영상 합치기)

나뉘어 찍힌 영상을 하나로 붙여 주는 윈도우 프로그램입니다. 앞뒤 자르기, 소리·밝기 조절, 회전, 전환 효과까지 할 수 있고, 글씨와 버튼이 큼직합니다.

[English](#english) below.

## 다운로드

[Releases](https://github.com/rere1123rgb/videojoin/releases)에서 `videojoin-*.zip`을 받아 압축을 풀고 `videojoin.exe`를 실행합니다. 설치는 필요 없고 ffmpeg가 들어 있습니다. 윈도우 10/11(64비트)용입니다.

코드 서명이 없어서 처음 실행할 때 파란 "Windows의 PC 보호" 창이 뜰 수 있습니다. **추가 정보 → 실행**을 누르면 됩니다.

## 이런 게 편해요

- **금방 끝납니다.** 형식이 같은 영상은 다시 만들지 않고 그대로 이어 붙입니다.
- **크기나 프레임레이트가 달라도 그냥 넣으면 됩니다.** 추천 설정을 제시하고, 기본값은 넣은 영상 중 가장 좋은 화질입니다.
- **간단한 손질은 여기서 끝낼 수 있습니다.** 앞뒤 자르기, 가운데 빼기, 소리·밝기 조절, 회전, 전환 효과 8가지.
- **돌려 놓고 자도 됩니다.** 작업 대기열, 절전 모드 막기, 중간에 꺼져도 이어서 만들기, 끝나면 컴퓨터 끄기.
- **용량을 줄일 수도 있습니다.** H.265를 고르면 약 40% 작아지고, 만들기 전에 예상 용량을 보여 줍니다.

인터넷에 아무것도 보내지 않습니다(업데이트 확인·통계·오류 전송 없음). 맥은 지원하지 않습니다.

## 라이선스

프로그램은 [MIT 라이선스](LICENSE)입니다. 함께 들어 있는 ffmpeg는 GPL v3이며, 버전과 소스 위치는 [licenses/THIRD_PARTY_NOTICES.txt](licenses/THIRD_PARTY_NOTICES.txt)에 있습니다.

---

## English

Windows desktop app that joins multiple video files into one, with simple trimming, volume/brightness adjustment and transitions.

> The UI is available in Korean only.

### Download

See [Releases](https://github.com/rere1123rgb/videojoin/releases). Unzip and run `videojoin.exe` (ffmpeg included).

### Build

Requirements: Flutter (Windows desktop), Visual Studio Build Tools (C++), `tools/ffmpeg.exe` and `tools/ffprobe.exe` (not included in the repository).

```powershell
flutter pub get
flutter test
powershell -ExecutionPolicy Bypass -File build_release.ps1 -Web
```

Output: `dist/web/videojoin/`

### License

MIT (see [LICENSE](LICENSE)). The bundled ffmpeg binaries are GPL v3; version and source links are in [licenses/THIRD_PARTY_NOTICES.txt](licenses/THIRD_PARTY_NOTICES.txt).
