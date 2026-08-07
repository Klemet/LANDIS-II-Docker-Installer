#requires -Version 5.1
$ErrorActionPreference = 'Continue'

<#
.SYNOPSIS
    LANDIS-II Docker Simulation Launcher.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Disable QuickEdit mode so accidental mouse-selection does not pause the launcher
try {
    $sig = '[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int nStdHandle); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(System.IntPtr h, out uint lpMode); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(System.IntPtr h, uint dwMode);'
    if (-not ("Win32.QuickEditUtils" -as [type])) {
        Add-Type -MemberDefinition $sig -Name "QuickEditUtils" -Namespace "Win32" | Out-Null
    }
    $h = [Win32.QuickEditUtils]::GetStdHandle(-10)
    if ($h -ne [IntPtr]::Zero) {
        [uint32]$m = 0
        if ([Win32.QuickEditUtils]::GetConsoleMode($h, [ref]$m)) {
            $m = $m -band (-bnot 0x40)
            [Win32.QuickEditUtils]::SetConsoleMode($h, $m) | Out-Null
        }
    }
} catch {
    # Harmless no-op in non-console hosts
}

function Select-FolderModern {
    param([string]$Title = 'Select a folder')
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title            = $Title
    $dlg.Filter           = 'Folders|*.folder'
    $dlg.FileName         = 'Select Folder'
    $dlg.CheckFileExists  = $false
    $dlg.CheckPathExists  = $true
    $dlg.ValidateNames    = $false
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return [System.IO.Path]::GetDirectoryName($dlg.FileName)
    }
    return $null
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "          LANDIS-II Docker Launcher" -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

# --- Check Docker running ---
Write-Host "  [*] Checking Docker..." -ForegroundColor Cyan
docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [✗] Docker is not running. Please start Docker Desktop and retry." -ForegroundColor Red
    Read-Host "  Press ENTER to exit"
    exit 1
}
Write-Host "  [✓] Docker is running" -ForegroundColor Green

# --- Check image ---
$image = "landis-ii-v8-uclv2-diverse:latest"
docker image inspect $image 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [✗] Docker image '$image' not found." -ForegroundColor Red
    Write-Host "      Please run the installer first to build the image." -ForegroundColor Yellow
    Read-Host "  Press ENTER to exit"
    exit 1
}
Write-Host "  [✓] Docker image found: $image" -ForegroundColor Green

# --- Select simulation folder ---
Write-Host "  [*] Select the SIMULATION FOLDER..." -ForegroundColor Cyan
$SIMULATION_FOLDER = Select-FolderModern -Title "Select the simulation folder"
if (-not $SIMULATION_FOLDER) {
    Write-Host "  [*] Cancelled. Exiting." -ForegroundColor Gray
    exit 0
}
Write-Host "  [✓] Simulation folder: $SIMULATION_FOLDER" -ForegroundColor Green

# --- Select scenario file ---
Write-Host "  [*] Select the scenario .txt file..." -ForegroundColor Cyan
$fileBrowser = New-Object System.Windows.Forms.OpenFileDialog
$fileBrowser.Title = "Select the scenario file"
$fileBrowser.InitialDirectory = $SIMULATION_FOLDER
$fileBrowser.Filter = "Scenario files (*.txt)|*.txt|All files (*.*)|*.*"
if ($fileBrowser.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "  [*] Cancelled. Exiting." -ForegroundColor Gray
    exit 0
}
$SCENARIO_FILE = $fileBrowser.FileName

# --- Derive paths ---
$scenarioFolder = Split-Path $SCENARIO_FILE -Parent
$scenarioName   = Split-Path $SCENARIO_FILE -Leaf
$relativeFolder = $scenarioFolder.Replace($SIMULATION_FOLDER, '').TrimStart('\', '/')

$subfolderCd = if ($relativeFolder) {
    "cd /scenarioFolder/$($relativeFolder.Replace('\', '/')) && "
} else {
    ''
}

$innerCmd = "${subfolderCd}dotnet `$LANDIS_CONSOLE `"$scenarioName`""
$displayCmd = 'docker run --rm --mount type=bind,src="{0}",dst=/scenarioFolder landis-ii-v8-uclv2-diverse /bin/sh -c "{1}"' -f $SIMULATION_FOLDER, $innerCmd

Write-Host ""
Write-Host "  Running simulation..." -ForegroundColor Cyan
Write-Host "  Simulation folder: $SIMULATION_FOLDER" -ForegroundColor Gray
Write-Host "  Scenario file:     $scenarioName" -ForegroundColor Gray
Write-Host "  Command: $displayCmd" -ForegroundColor DarkGray
Write-Host "  ---" -ForegroundColor Gray
& docker run --rm --mount "type=bind,src=$SIMULATION_FOLDER,dst=/scenarioFolder" landis-ii-v8-uclv2-diverse /bin/sh -c $innerCmd

Write-Host ""
Write-Host "  [✓] Simulation finished." -ForegroundColor Green
Read-Host "  Press ENTER to exit"