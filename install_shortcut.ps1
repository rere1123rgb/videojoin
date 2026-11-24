# 바탕화면과 시작 메뉴에 "영상 합치기" 바로가기를 만든다.
#
# UTF-8 BOM 필수(없으면 PowerShell 5.1 이 CP949 로 읽는다).
#
# 사용법 (보통은 "바로가기 만들기.bat" 실행):
#   powershell -ExecutionPolicy Bypass -File install_shortcut.ps1 -AppDir "C:\videojoin"

param(
  [string]$AppDir = ""
)

$ErrorActionPreference = "Stop"

if (-not $AppDir) {
  $here = Split-Path -Parent $MyInvocation.MyCommand.Path
  $guess = Join-Path $here "videojoin"
  if (Test-Path (Join-Path $guess "videojoin.exe")) {
    $AppDir = $guess
  } elseif (Test-Path (Join-Path $here "videojoin.exe")) {
    $AppDir = $here
  } else {
    Write-Host "  videojoin.exe 를 찾을 수 없습니다." -ForegroundColor Red
    exit 1
  }
}

$AppDir = (Resolve-Path -LiteralPath $AppDir).Path
$exe = Join-Path $AppDir "videojoin.exe"
if (-not (Test-Path $exe)) {
  Write-Host "  videojoin.exe 를 찾을 수 없습니다: $exe" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "  바탕화면과 시작 메뉴에 바로가기를 만듭니다."
Write-Host ""

$name = "영상 합치기"
$ws = New-Object -ComObject WScript.Shell

$desktop = [Environment]::GetFolderPath("Desktop")
$lnk = $ws.CreateShortcut((Join-Path $desktop "$name.lnk"))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $AppDir
$lnk.IconLocation = "$exe,0"
$lnk.Description = $name
$lnk.Save()
Write-Host "  [완료] 바탕화면"

$startMenu = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"
if (Test-Path $startMenu) {
  $lnk2 = $ws.CreateShortcut((Join-Path $startMenu "$name.lnk"))
  $lnk2.TargetPath = $exe
  $lnk2.WorkingDirectory = $AppDir
  $lnk2.IconLocation = "$exe,0"
  $lnk2.Description = $name
  $lnk2.Save()
  Write-Host "  [완료] 시작 메뉴"
}

Write-Host ""
Write-Host "  이제 바탕화면의 아이콘을 두 번 눌러 실행하세요."