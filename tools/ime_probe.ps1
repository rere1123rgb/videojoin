# Types Korean into the suffix TextField through the real Windows IME and
# reads back exactly what the app stored, as code points.
#
# WHY: if a rebuild happens mid-composition, jamo leak out as separate
# characters instead of one syllable. Console output can be mangled by CP949,
# so the result is compared as code points.
#
# Keep this file ASCII-only (PowerShell 5.1 reads BOM-less UTF-8 as CP949).
#
#   powershell -ExecutionPolicy Bypass -File tools\ime_probe.ps1

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public struct IRC { public int L,T,R,B; }
public class IME {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out IRC r);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,int dx,int dy,int d,int e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk,byte sc,uint f,int e);
}
'@
[void][IME]::SetProcessDPIAware()

function Key([byte]$vk, [int]$ms = 110) {
  [IME]::keybd_event($vk, 0, 0, 0)
  Start-Sleep -Milliseconds 25
  [IME]::keybd_event($vk, 0, 2, 0)
  Start-Sleep -Milliseconds $ms
}

$p = Get-Process videojoin -ErrorAction Stop
[void][IME]::SetForegroundWindow($p.MainWindowHandle)
Start-Sleep -Milliseconds 700

$r = New-Object IRC
[void][IME]::GetWindowRect($p.MainWindowHandle, [ref]$r)
$w = $r.R - $r.L
$h = $r.B - $r.T

# Suffix field position as fractions of the window, so it survives resizing.
$cx = $r.L + [int]($w * 0.552)
$cy = $r.T + [int]($h * 0.651)
Write-Output "click   : $cx,$cy   (window ${w}x${h} at $($r.L),$($r.T))"

[void][IME]::SetCursorPos($cx, $cy)
Start-Sleep -Milliseconds 250
[IME]::mouse_event(0x0002,0,0,0,0); Start-Sleep -Milliseconds 60
[IME]::mouse_event(0x0004,0,0,0,0)
Start-Sleep -Milliseconds 600

[IME]::keybd_event(0x11,0,0,0); Key 0x41 60; [IME]::keybd_event(0x11,0,2,0)
Start-Sleep -Milliseconds 200
Key 0x2E 300

# Switch to Korean, then type the dubeolsik keys for two syllables.
#   h k q -> first syllable, c l a -> second syllable
Key 0x15 700
foreach ($k in @(0x48,0x4B,0x51,0x43,0x4C,0x41)) { Key $k 160 }

# Commit the trailing composition, then restore the IME state.
Start-Sleep -Milliseconds 400
Key 0x0D 500
Key 0x15 300

$prefs = Join-Path $env:APPDATA "com.example\videojoin\shared_preferences.json"
if (-not (Test-Path $prefs)) { throw "prefs not found: $prefs" }
$json = Get-Content $prefs -Raw -Encoding UTF8 | ConvertFrom-Json
$val = [string]$json.'flutter.nameSuffix'

Write-Output ""
Write-Output "stored  : $($val.Length) chars"
$cps = ($val.ToCharArray() | ForEach-Object { "U+{0:X4}" -f [int]$_ }) -join " "
Write-Output "codepts : $cps"
Write-Output ""

# Hangul syllable block is U+AC00..U+D7A3; bare jamo live in U+3130..U+318F.
$jamo = @($val.ToCharArray() | Where-Object { [int]$_ -ge 0x3130 -and [int]$_ -le 0x318F }).Count
$syll = @($val.ToCharArray() | Where-Object { [int]$_ -ge 0xAC00 -and [int]$_ -le 0xD7A3 }).Count
Write-Output "syllables=$syll  loose-jamo=$jamo"
if ($jamo -gt 0 -or $syll -ne 2) {
  Write-Output "RESULT  : BROKEN (expected exactly 2 syllables, 0 loose jamo)"
} else {
  Write-Output "RESULT  : OK"
}
