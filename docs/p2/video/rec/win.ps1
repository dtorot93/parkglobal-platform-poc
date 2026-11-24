# Ventanas del monitor de grabación: win.ps1 front|max|zoom <terminal|chrome> [n]
param([string]$cmd, [string]$who, [int]$n = 1)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e); }
"@
if ($who -eq "terminal") { $p = Get-Process WindowsTerminal -ErrorAction SilentlyContinue | ? { $_.MainWindowHandle -ne 0 } | select -First 1 }
else { $p = Get-Process chrome | ? { $_.MainWindowTitle -match "Chrome" -and $_.MainWindowTitle -notmatch "^GitHub - Google Chrome$" } | sort StartTime | select -Last 1 }
if (-not $p) { "no encontrada: $who"; exit 1 }
$h = $p.MainWindowHandle
[W]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [W]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # Alt: permite traer al frente
if ($cmd -eq "max") { [W]::ShowWindow($h, 3) | Out-Null }
[W]::SetForegroundWindow($h) | Out-Null
if ($cmd -eq "zoom") { Start-Sleep -Milliseconds 300; for ($i = 0; $i -lt $n; $i++) { [W]::keybd_event(0x11,0,0,[UIntPtr]::Zero); [W]::keybd_event(0xBB,0,0,[UIntPtr]::Zero); [W]::keybd_event(0xBB,0,2,[UIntPtr]::Zero); [W]::keybd_event(0x11,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 120 } }
"$cmd $who -> " + $p.MainWindowTitle
