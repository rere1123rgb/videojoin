# Launches videojoin and moves it onto the secondary monitor.
# Keep this file ASCII-only (PowerShell 5.1 reads BOM-less UTF-8 as CP949).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\run_on_2nd.ps1 -Exe "dist\videojoin\videojoin.exe" -Files a.mp4,b.mp4

param(
  [string]$Exe = "",
  [string[]]$Files = @(),
  [int]$Width = 2600,
  [int]$Height = 1500
)

$ErrorActionPreference = "Stop"

# When invoked as `powershell -File script.ps1 -Files a,b,c`, PowerShell hands
# the whole list over as ONE string. Split it back apart.
if ($Files.Count -eq 1 -and $Files[0] -match ',') {
  $Files = $Files[0] -split ',' | Where-Object { $_ -ne '' }
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Exe) {
  $cands = @(
    (Join-Path $root "dist\videojoin\videojoin.exe"),
    (Join-Path $root "build\windows\x64\runner\Release\videojoin.exe"),
    (Join-Path $root "build\windows\x64\runner\Debug\videojoin.exe")
  )
  foreach ($c in $cands) { if (Test-Path $c) { $Exe = $c; break } }
}
if (-not $Exe -or -not (Test-Path $Exe)) { throw "videojoin.exe not found" }

$code = 'using System;
using System.Runtime.InteropServices;
public struct VJRect { public int L, T, R, B; }
public class VJMove {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool rp);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out VJRect r);
}'
Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
[void][VJMove]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms

# Pick the secondary monitor; fall back to primary if there is only one.
$screens = [System.Windows.Forms.Screen]::AllScreens
$target = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
if (-not $target) { $target = $screens[0] }
$b = $target.Bounds

Get-Process videojoin -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

$quoted = $Files | ForEach-Object { '"' + (Resolve-Path -LiteralPath $_).Path + '"' }
if ($quoted.Count -gt 0) {
  Start-Process -FilePath $Exe -ArgumentList $quoted -WorkingDirectory (Split-Path -Parent $Exe)
} else {
  Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe)
}

# Poll for the window handle and move it as soon as it exists.
$p = $null
for ($i = 0; $i -lt 120; $i++) {
  Start-Sleep -Milliseconds 250
  $p = Get-Process videojoin -ErrorAction SilentlyContinue
  if ($p -and $p.MainWindowHandle -ne 0) { break }
}
if (-not $p -or $p.MainWindowHandle -eq 0) { throw "window did not appear" }

$w = [Math]::Min($Width, $b.Width)
$h = [Math]::Min($Height, $b.Height)
$x = $b.X + [int](($b.Width - $w) / 2)
$y = $b.Y + [int](($b.Height - $h) / 2)

# Retry the move: crossing to a monitor with a different DPI triggers
# WM_DPICHANGED, so the first move lands off-target.
$r = New-Object VJRect
for ($try = 0; $try -lt 4; $try++) {
  [void][VJMove]::MoveWindow($p.MainWindowHandle, $x, $y, $w, $h, $true)
  Start-Sleep -Milliseconds 450
  [void][VJMove]::GetWindowRect($p.MainWindowHandle, [ref]$r)
  if ($r.L -ge ($b.X - 8) -and $r.R -le ($b.X + $b.Width + 8)) { break }
}
[void][VJMove]::SetForegroundWindow($p.MainWindowHandle)
[void][VJMove]::GetWindowRect($p.MainWindowHandle, [ref]$r)
Write-Output ("monitor : {0} {1}" -f $target.DeviceName, $b)
Write-Output ("window  : ({0},{1}) {2}x{3}" -f $r.L, $r.T, ($r.R - $r.L), ($r.B - $r.T))
