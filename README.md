# videojoin (영상 합치기)

Windows desktop app that joins multiple video files into one, with simple trimming, volume/brightness adjustment and transitions.

> The UI is available in Korean only. (화면은 한국어만 지원합니다.)

## Download

See [Releases](https://github.com/rere1123rgb/videojoin/releases). Unzip and run `videojoin.exe` (ffmpeg included).

## Build

Requirements: Flutter (Windows desktop), Visual Studio Build Tools (C++), `tools/ffmpeg.exe` and `tools/ffprobe.exe` (not included in the repository).

```powershell
flutter pub get
flutter test
powershell -ExecutionPolicy Bypass -File build_release.ps1 -Web
```

Output: `dist/web/videojoin/`
