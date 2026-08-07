#requires -Version 5.1
$ErrorActionPreference = 'Continue'

$installDir  = "C:\Program Files\LANDIS-II Docker Launcher"
$shortcutDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\LANDIS-II Docker Launcher"

Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $shortcutDir -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  LANDIS-II Docker Launcher has been uninstalled." -ForegroundColor Green
Write-Host ""
Read-Host "  Press ENTER to exit"