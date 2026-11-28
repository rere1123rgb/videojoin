# Release build + distribution packaging. Keep this file ASCII-only
# (Windows PowerShell 5.1 reads BOM-less UTF-8 as the ANSI codepage).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build_release.ps1 [-NoPackage] [-DartOnly] [-Web]
#
# -NoPackage: build only; do not touch dist\.
# -DartOnly:  rebuild only the Dart code (app.so + assets) and reuse the native
#             runner exe of the last full build. Fallback for when
#             `flutter build` cannot find Visual Studio. Changes under windows\
#             and the exe version resource are not picked up.
# -Web:       public edition: built without personal.json (no signature
#             compiled in), packaged into dist\web. Always a full build.
#
# personal.json (git-ignored) holds the signature defines, passed with
# --dart-define-from-file: {"VJ_AUTHOR": "...", "VJ_CHEER": "..."}
param([switch]$DartOnly, [switch]$NoPackage, [switch]$Web)

$ErrorActionPreference = "Stop"

$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$link = "C:\vjsrc"
$dist = Join-Path $src "dist"
if ($Web) { $dist = Join-Path $src "dist\web" }
$appName = "videojoin"
$personal = Join-Path $src "personal.json"
if ($Web -and $DartOnly) { throw "-Web needs a full build (do not combine with -DartOnly)" }
# The compiler embeds the absolute project path in app.so
# (file:///.../.dart_tool/flutter_build/dart_plugin_registrant.dart),
# so build the public edition from a folder outside the user profile.
if ($Web -and ($src -match '\\Users\\')) { throw "-Web: build from a folder outside C:\Users (the project path is compiled into app.so), e.g. C:\vjpub" }

# A running instance locks its DLLs, so close it before replacing dist\.
Get-Process $appName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600

Write-Output "source   : $src"

# 1) MSBuild/gen_snapshot lose non-ASCII path characters (flutter#111446), so a
#    non-ASCII project path is built through an ASCII directory junction.
if ($src -match '[^\x00-\x7F]') {
  Write-Output "[1/4] non-ASCII path: preparing ASCII junction $link ..."
  if (Test-Path $link) { cmd /c rmdir "$link" 2>$null | Out-Null }
  cmd /c mklink /J "$link" "$src" | Out-Null
  if (-not (Test-Path (Join-Path $link "pubspec.yaml"))) { throw "junction failed: $link" }
} else {
  Write-Output "[1/4] ASCII path: building in place"
  $link = $src
}
Write-Output "build in : $link"
Write-Output ""

Write-Output "[2/4] building release (this takes a few minutes)..."
Push-Location $link
try {
  if ($DartOnly) {
    # Find MSBuild through vswhere; fall back to the VS 2019 path.
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msb = $null
    if (Test-Path $vswhere) {
      $msb = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
    }
    if (-not $msb) { $msb = "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe" }
    $bdir = Join-Path $link "build\windows\x64"
    if (-not (Test-Path $msb)) { throw "MSBuild not found: $msb" }
    if (-not (Test-Path (Join-Path $bdir "runner\Release\$appName.exe"))) {
      throw "-DartOnly needs a previous full build (no runner exe yet)"
    }
    $soFile = Join-Path $link "build\windows\app.so"
    # An up-to-date app.so is not rewritten, so compare it to the newest source.
    $newestSrc = (Get-ChildItem (Join-Path $link "lib") -Recurse -Filter *.dart | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc

    & flutter pub get | Out-Null
    # -DartOnly reuses the Dart defines of the last full build (in
    # generated_config.cmake). After a -Web build those lack the signature,
    # so refuse rather than ship an unsigned normal build.
    if (Test-Path $personal) {
      $cfg = Get-Content (Join-Path $link "windows\flutter\ephemeral\generated_config.cmake") -Raw
      $hasAuthor = $false
      if ($cfg -match 'DART_DEFINES=([^"]*)"') {
        foreach ($e in $Matches[1].Split(',')) {
          try { $t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($e)) } catch { continue }
          if ($t.StartsWith('VJ_AUTHOR=')) { $hasAuthor = $true }
        }
      }
      if (-not $hasAuthor) { throw "-DartOnly: last full build had no personal.json defines; run a full build first" }
    }
    & $msb (Join-Path $bdir "flutter\flutter_assemble.vcxproj") /p:Configuration=Release /p:Platform=x64 /p:BuildProjectReferences=false /nologo /v:quiet | Out-Null
    $after = if (Test-Path $soFile) { (Get-Item $soFile).LastWriteTimeUtc } else { [datetime]::MinValue }
    if ($after -lt $newestSrc) { throw "Dart build failed: app.so is older than the Dart sources" }

    & $msb (Join-Path $bdir "INSTALL.vcxproj") /p:Configuration=Release /p:Platform=x64 /p:BuildProjectReferences=false /nologo /v:quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "install step failed" }
    $LASTEXITCODE = 0
    Write-Output "      Dart-only build ok (native runner reused)"
  } else {
    $fbArgs = @("build", "windows", "--release")
    if ((-not $Web) -and (Test-Path $personal)) {
      $fbArgs += "--dart-define-from-file=$personal"
      Write-Output "      with personal.json (signature)"
    } else {
      Write-Output "      without personal.json (no signature)"
    }
    & flutter @fbArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed (if Visual Studio is not found, try -DartOnly)" }
  }
} finally {
  Pop-Location
}

if ($NoPackage) {
  Write-Output ""
  Write-Output ("DONE (no package): " + (Join-Path $src "build\windows\x64\runner\Release\$appName.exe"))
  exit 0
}

$out = Join-Path $src "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $out "$appName.exe"))) { throw "no build output at $out" }

# 3) ffmpeg must ship next to the exe; verify (CMake normally installs it).
Write-Output "[3/4] verifying bundled ffmpeg..."
foreach ($f in @("ffmpeg.exe", "ffprobe.exe")) {
  $dstFile = Join-Path $out $f
  if (-not (Test-Path $dstFile)) {
    Copy-Item (Join-Path $src "tools\$f") $dstFile -Force
    Write-Output "      copied $f"
  } else {
    Write-Output "      ok     $f"
  }
}

# 3b) Bundle the VC++ runtime next to the exe (app-local deployment) so a clean
#     target PC does not fail with "MSVCP140.dll was not found".
Write-Output "[3b/4] bundling Visual C++ runtime..."
$crtNeeded = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")
$vcRoot = "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Redist\MSVC"
$crtDir = $null
if (Test-Path $vcRoot) {
  $crtDir = Get-ChildItem $vcRoot -Directory |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName "x64\Microsoft.VC142.CRT" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
}
foreach ($d in $crtNeeded) {
  $dst = Join-Path $out $d
  if (Test-Path $dst) { Write-Output "      ok     $d"; continue }
  $srcDll = $null
  if ($crtDir) { $cand = Join-Path $crtDir $d; if (Test-Path $cand) { $srcDll = $cand } }
  if (-not $srcDll) {
    $cand = Join-Path $env:SystemRoot "System32\$d"
    if (Test-Path $cand) { $srcDll = $cand }
  }
  if ($srcDll) {
    Copy-Item $srcDll $dst -Force
    Write-Output "      copied $d"
  } else {
    throw "missing Visual C++ runtime DLL: $d (app will not start on a clean PC)"
  }
}

# 4) Collect into dist\videojoin
Write-Output "[4/4] packaging into dist..."
$appDir = Join-Path $dist $appName
if (Test-Path $appDir) { cmd /c rd /s /q "$appDir" 2>$null | Out-Null }
New-Item -ItemType Directory -Force $appDir | Out-Null
robocopy $out $appDir /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
$LASTEXITCODE = 0

# Licenses: the app (MIT) and the bundled ffmpeg (GPLv3) with its source location.
Copy-Item (Join-Path $src "LICENSE") (Join-Path $appDir "LICENSE.txt") -Force
Copy-Item (Join-Path $src "licenses") (Join-Path $appDir "licenses") -Recurse -Force
Write-Output "      added  LICENSE.txt + licenses\"

# Shortcut maker .bat inside the app folder; it launches install_shortcut.ps1.
# Its Korean filename is built from code points to keep this file ASCII.
$helper = Join-Path $src "install_shortcut.ps1"
$batSrc = Join-Path $src "tools\make_shortcut.bat"
if ((Test-Path $batSrc) -and (Test-Path $helper)) {
  Copy-Item $helper $appDir -Force
  $batName = [string][char]0xBC14 + [char]0xB85C + [char]0xAC00 + [char]0xAE30 +
             ' ' + [char]0xB9CC + [char]0xB4E4 + [char]0xAE30 + '.bat'
  Copy-Item $batSrc (Join-Path $appDir $batName) -Force
  Write-Output "      added  $batName (+ install_shortcut.ps1)"
} else {
  throw "shortcut helper missing: $batSrc / $helper"
}

if (Test-Path $helper) { Copy-Item $helper $dist -Force }

# Remove the junction only ($link is the project folder itself on ASCII paths).
if ($link -ne $src) { cmd /c rmdir "$link" 2>$null | Out-Null }

$size = (Get-ChildItem $appDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Output ""
Write-Output "DONE: $appDir"
Write-Output ("size: {0:N0} MB" -f ($size / 1MB))
Write-Output ""
Write-Output "To install on the user's PC:"
Write-Output "  1. copy the '$appName' folder anywhere (e.g. C:\Program Files\videojoin)"
Write-Output "  2. run install_shortcut.ps1 to create desktop + start menu shortcuts"
