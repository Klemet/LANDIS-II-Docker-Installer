#requires -Version 5.1
$ErrorActionPreference = 'Continue'

$installDir  = "C:\Program Files\LANDIS-II Docker Launcher"
$shortcutDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\LANDIS-II Docker Launcher"
$dataDir     = "$env:LOCALAPPDATA\LANDIS-II-Docker"

# --- Admin check (removing Program Files / ProgramData requires elevation) ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  ERROR: This uninstaller must be run as an Administrator." -ForegroundColor Red
    Write-Host "  Right-click it and choose 'Run as administrator' (the installed" -ForegroundColor Yellow
    Write-Host "  'Uninstall LANDIS-II Docker Launcher' exe requests this automatically)." -ForegroundColor Yellow
    Read-Host "  Press ENTER to exit"
    exit 1
}

# Move the working directory off the install folder so its handle isn't held open
# while we try to delete it (the launcher/uninstaller may run from that directory).
Set-Location -LiteralPath $env:SystemRoot

Write-Host ""
Write-Host "  Uninstalling LANDIS-II Docker Launcher..." -ForegroundColor Cyan

foreach ($path in @($installDir, $shortcutDir, $dataDir)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $path) {
            Write-Host "  [✗] Could not remove: $path" -ForegroundColor Red
        } else {
            Write-Host "  [✓] Removed: $path" -ForegroundColor Green
        }
    } else {
        Write-Host "  [*] Not present: $path" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "  LANDIS-II Docker Launcher has been uninstalled." -ForegroundColor Green
Write-Host ""
Read-Host "  Press ENTER to exit"
