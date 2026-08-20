#requires -Version 5.1
<#
.SYNOPSIS
    LANDIS-II Docker Installer for Windows.
.DESCRIPTION
    Installs, runs, and manages the LANDIS-II Forest Landscape Model via Docker.
    Automates WSL2 setup, Docker Desktop verification, two-stage Docker image
    builds from pinned GitHub commits, and installs a user-friendly launcher.
.NOTES
    Must be run as an administrator.
#>

# NOTE: Do NOT set a global $ErrorActionPreference='Stop'. Native-command stderr
# redirected via 2>&1 (e.g. `docker info 2>&1`) would then throw whenever the
# command reports an error, breaking Docker/WSL detection and build logging.
# Explicit -ErrorAction Stop is used on the specific cmdlets that require it.

# ==== CONSOLE TWEAKS ==========================================================

# Disable QuickEdit mode so accidental mouse-selection does not pause the script.
function Disable-ConsoleQuickEdit {
    try {
        $sig = '[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int nStdHandle); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(System.IntPtr h, out uint lpMode); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(System.IntPtr h, uint dwMode);'
        if (-not ("Win32.QuickEditUtils" -as [type])) {
            Add-Type -MemberDefinition $sig -Name "QuickEditUtils" -Namespace "Win32" | Out-Null
        }
        $h = [Win32.QuickEditUtils]::GetStdHandle(-10)   # -10 = STD_INPUT_HANDLE
        if ($h -ne [IntPtr]::Zero) {
            [uint32]$mode = 0
            if ([Win32.QuickEditUtils]::GetConsoleMode($h, [ref]$mode)) {
                $mode = $mode -band (-bnot 0x40)  # clear ENABLE_QUICK_EDIT_MODE
                [Win32.QuickEditUtils]::SetConsoleMode($h, $mode) | Out-Null
            }
        }
    } catch {
        # Harmless no-op if the console does not support this (e.g. Windows Terminal)
    }
}
Disable-ConsoleQuickEdit

# ==== STARTUP & ADMIN CHECK ==================================================

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host ""
    Write-Host "  ERROR: This script must be run as an Administrator." -ForegroundColor Red
    Write-Host "  Elevated privileges are required, especially on government/restricted machines." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Please run the provided LANDIS-II-Docker-Installer.exe (it requests elevation" -ForegroundColor Yellow
    Write-Host "  automatically), or right-click this script and choose 'Run as administrator'." -ForegroundColor Yellow
    Read-Host "  Press ENTER to exit"
    exit 1
}

# ==== GLOBAL STATE ============================================================

$appRoot   = "$env:LOCALAPPDATA\LANDIS-II-Docker"
$sentinel  = "$appRoot\sentinel"
$repoDir   = "$appRoot\repos"
$logDir    = "$appRoot\logs"
$installDir = "C:\Program Files\LANDIS-II Docker Launcher"
$shortcutDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\LANDIS-II Docker Launcher"

$baseImage   = "landis-ii-v8-uclv2-release:ubuntu-26.04"
$diverseImage = "landis-ii-v8-uclv2-diverse:latest"

$portableGitInstalled = $false
$gitTempDir = $null
$gitExe = "git"

# ==== UI HELPERS ==============================================================

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "        LANDIS-II Docker Installer" -ForegroundColor Cyan
    Write-Host "   Forest Landscape Model via Docker on Windows" -ForegroundColor Cyan
    Write-Host "   Version 1.0.0" -ForegroundColor DarkGray
    Write-Host "   By Clément Hardy, PhD." -ForegroundColor DarkGray
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Pause-Prompt {
    Write-Host ""
    Write-Host "  Press ENTER to continue..." -ForegroundColor White
    Read-Host | Out-Null
}

# ==== FOLDER PICKER / BUILD HELPERS ===========================================

# Native modern "pick a folder" dialog (Win10/11 style) via IFileOpenDialog + FOS_PICKFOLDERS.
# The COM interop is done in C# (where coclass->interface casting is reliable) and exposed
# as a simple static method. Unlike the old OpenFileDialog hack, the dialog's "Select Folder"
# button always confirms the highlighted folder instead of sometimes just navigating into it.
Add-Type -AssemblyName System.Windows.Forms
if (-not ("NativeInterop.FolderPicker" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace NativeInterop
{
    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    public class FileOpenDialogRCW { }

    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr hwndOwner);
        [PreserveSig] int SetFileTypes(uint cFileTypes, [In] IntPtr rgFilterSpec);
        [PreserveSig] int SetFileTypeIndex(uint iFileType);
        [PreserveSig] int GetFileTypeIndex(out uint piFileType);
        [PreserveSig] int Advise([In, MarshalAs(UnmanagedType.Interface)] object pfde, out uint pdwCookie);
        [PreserveSig] int Unadvise(uint dwCookie);
        [PreserveSig] int SetOptions(uint fos);
        [PreserveSig] int GetOptions(out uint pfos);
        [PreserveSig] int SetDefaultFolder([In, MarshalAs(UnmanagedType.Interface)] object psi);
        [PreserveSig] int SetFolder([In, MarshalAs(UnmanagedType.Interface)] object psi);
        [PreserveSig] int GetFolder([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int GetCurrentSelection([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int SetFileName([In, MarshalAs(UnmanagedType.LPWStr)] string pszName);
        [PreserveSig] int GetFileName([Out, MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        [PreserveSig] int SetTitle([In, MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        [PreserveSig] int SetOkButtonLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszText);
        [PreserveSig] int SetFileNameLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        [PreserveSig] int GetResult([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int AddPlace([In, MarshalAs(UnmanagedType.Interface)] object psi, int fdap);
        [PreserveSig] int SetDefaultExtension([In, MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        [PreserveSig] int Close(int hr);
        [PreserveSig] int SetClientGuid([In] ref Guid guid);
        [PreserveSig] int ClearClientData();
        [PreserveSig] int SetFilter([In, MarshalAs(UnmanagedType.Interface)] object pFilter);
        [PreserveSig] int GetResults([MarshalAs(UnmanagedType.Interface)] out object ppenum);
        [PreserveSig] int GetSelectedItems([MarshalAs(UnmanagedType.Interface)] out object ppsai);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        [PreserveSig] int BindToHandler([In, MarshalAs(UnmanagedType.Interface)] object pbc,
            [In] ref Guid bhid, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);
        [PreserveSig] int GetParent([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int GetDisplayName(uint sigdnName, [Out, MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        [PreserveSig] int GetAttributes(ulong sfgaoMask, out ulong psfgaoAttribs);
        [PreserveSig] int Compare([In, MarshalAs(UnmanagedType.Interface)] object psi, int hint, out int piOrder);
    }

    public static class FolderPicker
    {
        const uint FOS_PICKFOLDERS     = 0x20;
        const uint FOS_FORCEFILESYSTEM = 0x40;
        const uint FOS_PATHMUSTEXIST   = 0x800;
        const uint SIGDN_FILESYSPATH   = 0x80058000;

        // Returns the selected folder path, or null if the user cancelled or an error occurred.
        public static string SelectFolder(string title)
        {
            try {
                IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogRCW();
                dlg.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
                dlg.SetTitle(title);
                dlg.SetOkButtonLabel("Select Folder");

                if (dlg.Show(IntPtr.Zero) < 0)
                    return null;   // cancelled (0x800704C7) or any other failure

                object item;
                dlg.GetResult(out item);
                IShellItem si = (IShellItem)item;

                string path;
                si.GetDisplayName(SIGDN_FILESYSPATH, out path);
                return path;
            }
            catch {
                return null;
            }
        }
    }
}
'@
}

function Select-FolderModern {
    param([string]$Title = 'Select a folder')
    return [NativeInterop.FolderPicker]::SelectFolder($Title)
}

function Invoke-DockerBuild {
    param(
        [string]$WorkDir,
        [string[]]$ArgsList,
        [string]$LogFile,
        [string]$Label
    )
    New-Item -ItemType Directory -Force -Path (Split-Path $LogFile -Parent) | Out-Null
    if (Test-Path $LogFile) { Remove-Item -Force $LogFile }

    Write-Host ""
    Write-Host ("  Building: {0}" -f $Label) -ForegroundColor Cyan
    Write-Host "  Please wait, the image is building (this stays running until it finishes)..." -ForegroundColor White
    Write-Host "  You can watch the progress in the log folder:" -ForegroundColor Gray
    Write-Host "      $logDir" -ForegroundColor Gray
    Write-Host ""

    Push-Location $WorkDir
    try {
        & docker $ArgsList *> $LogFile
    } finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host ("  Build finished (exit code {0}). Last lines of the log:" -f $LASTEXITCODE) -ForegroundColor DarkGray
    Get-Content -LiteralPath $LogFile -Tail 15 -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("      " + $_) -ForegroundColor DarkGray }
    Write-Host ""
}

function Get-GitRepo {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Commit
    )
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null

    # A fresh, clean target directory avoids "destination path already exists" errors
    if (Test-Path $Dest) {
        Write-Host ("  Clearing existing repository folder: {0}" -f $Dest) -ForegroundColor DarkGray
        Remove-Item -Recurse -Force $Dest -ErrorAction SilentlyContinue
    }

    Write-Host ("  Cloning {0}..." -f $Url) -ForegroundColor Cyan
    $cloneOut = (& $gitExe clone $Url $Dest) 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [✗] Failed to clone the repository." -ForegroundColor Red
        Write-Host ("      URL: {0}" -f $Url) -ForegroundColor Gray
        Write-Host ("      Destination: {0}" -f $Dest) -ForegroundColor Gray
        $cloneOut | ForEach-Object { Write-Host ("      $_") -ForegroundColor DarkGray }
        Write-Host "      Make sure the repository is reachable and the network is available." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [✓] Repository cloned" -ForegroundColor Green

    Write-Host ("  Checking out commit {0}..." -f $Commit) -ForegroundColor Cyan
    $checkoutOut = @()
    Push-Location $Dest
    try {
        $checkoutOut = (& $gitExe checkout $Commit) 2>&1
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [✗] Failed to checkout commit $Commit." -ForegroundColor Red
        $checkoutOut | ForEach-Object { Write-Host ("      $_") -ForegroundColor DarkGray }
        return $false
    }
    Write-Host ("  [✓] Checked out commit {0}" -f $Commit) -ForegroundColor Green
    return $true
}

# ==== ARROW-KEY MENU SYSTEM ===================================================

function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Options
    )
    $selection = 0
    while ($true) {
        Show-Header
        Write-Host "  $Title" -ForegroundColor Yellow
        Write-Host ""
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $selection) {
                Write-Host "  > $($Options[$i])" -ForegroundColor Cyan
            } else {
                Write-Host "    $($Options[$i])" -ForegroundColor White
            }
        }
        Write-Host ""
        Write-Host "  [↑↓] Navigate    [ENTER] Select" -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            ([ConsoleKey]::UpArrow)   { if ($selection -gt 0) { $selection-- } }
            ([ConsoleKey]::DownArrow) { if ($selection -lt $Options.Count - 1) { $selection++ } }
            ([ConsoleKey]::Enter)     { return $selection }
        }
    }
}

# ==== RESTRICTED ENVIRONMENT DETECTION ========================================

function Test-Environment {
    Write-Host "  [*] Checking environment..." -ForegroundColor Cyan

    # --- DNS check ---
    try {
        Resolve-DnsName github.com -ErrorAction Stop | Out-Null
        Write-Host "  [✓] DNS resolution to github.com OK" -ForegroundColor Green
    } catch {
        Write-Host "  [✗] Could not resolve github.com." -ForegroundColor Red
        Write-Host "      You may be affected by firewall, VPN, or proxy restrictions." -ForegroundColor Yellow
        Write-Host "      These will prevent cloning repos and pulling Docker images." -ForegroundColor Yellow
        Write-Host "      Continuing anyway; the build may fail." -ForegroundColor Yellow
    }

    # --- Execution policy ---
    $policy = Get-ExecutionPolicy
    if ($policy -eq 'Restricted') {
        Write-Host "  [✗] ExecutionPolicy is Restricted." -ForegroundColor Red
        try {
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
            Write-Host "  [✓] Set process-scope ExecutionPolicy to Bypass" -ForegroundColor Green
        } catch {
            Write-Host "      Could not change ExecutionPolicy for this process." -ForegroundColor Yellow
            Write-Host "      You may need to adjust policy settings (common on government machines)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [✓] ExecutionPolicy: $policy" -ForegroundColor Green
    }

    # --- AppLocker ---
    try {
        $appLocker = Get-AppLockerPolicy -Effective -ErrorAction Stop
        $rules = @($appLocker.RuleCollections)
        if ($rules.Count -gt 0) {
            Write-Host "  [*] AppLocker policy detected." -ForegroundColor Yellow
            Write-Host "      Execution from temp directories may be blocked." -ForegroundColor Yellow
        } else {
            Write-Host "  [✓] No AppLocker rules in effect" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [*] AppLocker policy unavailable to query." -ForegroundColor Gray
    }

    # --- Disk space ---
    $drive = Get-PSDrive -Name $env:SystemDrive.Substring(0, 1)
    if ($drive.Free -lt 10GB) {
        Write-Host "  [✗] Less than 10 GB free disk space on system drive." -ForegroundColor Red
        Write-Host "      Free: $([math]::Round($drive.Free / 1GB, 2)) GB" -ForegroundColor Yellow
        Write-Host "      Continue anyway? (Y/N)" -ForegroundColor Yellow
        $answer = Read-Host "  →"
        if ($answer -notmatch '^[Yy]') { Show-Header; Write-Host "  Exiting." -ForegroundColor Gray; exit }
    } else {
        Write-Host "  [✓] Free disk space: $([math]::Round($drive.Free / 1GB, 2)) GB" -ForegroundColor Green
    }
    Pause-Prompt
}

# ==== POST-BUILD VERIFICATION & ERROR CATEGORIZATION ==========================

function Get-BuildErrorCategory {
    param([string]$LogPath)
    $content = if (Test-Path $LogPath) { Get-Content -Raw $LogPath } else { "" }
    switch -Regex ($content) {
        'SSL|certificate|TLS|The remote name could not be resolved' {
            return "Network/SSL error - check proxy settings, firewall rules, VPN. Corporate networks may block Docker Hub or GitHub."
        }
        'Could not resolve host|Connection refused|timed out|Name or service not known' {
            return "Connection error - check internet connectivity. Docker daemon may not have network access. Restart Docker Desktop."
        }
        'error CS|MSB|dotnet build|Build FAILED|error :' {
            return ".NET compilation error - possible extension version incompatibility. A LANDIS-II extension may have changed repository or version."
        }
        "returned a non-zero code|The command '/bin/sh -c' returned" {
            return "Dockerfile step failure - a RUN command in the Dockerfile failed. Check the log for the specific step."
        }
        default {
            return "Unknown error - general build failure. See log for details."
        }
    }
}

function Test-DockerBuild {
    param(
        [string]$Image,
        [string]$LogFile
    )
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [✓] Docker build completed with exit code 0" -ForegroundColor Green
        docker image inspect $Image 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [✓] Image verified: $Image" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  [✗] Image not found after build. It may be corrupted." -ForegroundColor Red
            Write-Host "      Advise re-running the install." -ForegroundColor Yellow
            return $false
        }
    } else {
        Write-Host "  [✗] Docker build FAILED (exit code $LASTEXITCODE)" -ForegroundColor Red
        $advice = Get-BuildErrorCategory -LogPath $LogFile
        Write-Host "      Category: $advice" -ForegroundColor Yellow
        Write-Host "      Full log: $LogFile" -ForegroundColor Gray
        Write-Host "      If the problem persists, please report at:" -ForegroundColor Gray
        Write-Host "      https://github.com/LANDIS-II-Foundation/LANDIS-II" -ForegroundColor Gray
        return $false
    }
}

# ==== INSTALL FLOW ============================================================

function Test-WslPresent {
    $wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslExe) { return $false }
    $status = wsl --status 2>&1
    return $LASTEXITCODE -eq 0
}

function Install-Wsl {
    Write-Host "  [Step 1 of 6] Checking WSL2..." -ForegroundColor Magenta

    if (Test-WslPresent) {
        Write-Host "  [✓] WSL is installed and responding" -ForegroundColor Green
        return $true
    }

    Write-Host "  WSL not fully configured. Checking Windows features..." -ForegroundColor Cyan

    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction Stop
    $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction Stop

    $needsInstall = $false
    if ($wslFeature.State -ne 'Enabled') {
        $needsInstall = $true
        Write-Host "  Enabling: Microsoft-Windows-Subsystem-Linux..." -ForegroundColor Cyan
        Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart -ErrorAction Stop
    }
    if ($vmpFeature.State -ne 'Enabled') {
        $needsInstall = $true
        Write-Host "  Enabling: VirtualMachinePlatform..." -ForegroundColor Cyan
        Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -NoRestart -ErrorAction Stop
    }

    if ($needsInstall) {
        New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
        Set-Content -Path $sentinel -Value "STEP_AFTER_REBOOT" -Force
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Yellow
        Write-Host "  A REBOOT IS REQUIRED." -ForegroundColor Yellow
        Write-Host "  Please restart your computer, then re-run this script." -ForegroundColor Yellow
        Write-Host "  ============================================" -ForegroundColor Yellow
        Read-Host "  Press ENTER to exit"
        exit
    }

    # Features already enabled - proceed to install WSL
    Write-Host "  Installing WSL..." -ForegroundColor Cyan
    $installResult = wsl --install 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [✓] WSL installed" -ForegroundColor Green
        try { wsl --set-default-version 2 2>&1 | Out-Null } catch {}
        return $true
    } else {
        Write-Host "  [✗] Failed to install WSL." -ForegroundColor Red
        Write-Host "      Your Windows build may be too old." -ForegroundColor Yellow
        Write-Host "      See: https://learn.microsoft.com/en-us/windows/wsl/install" -ForegroundColor Gray
        Read-Host "  Press ENTER to return to the menu"
        return $false
    }
}

function Test-DockerRunning {
    docker info 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-DockerInstalled {
    return [bool](Get-Command docker -ErrorAction SilentlyContinue)
}

function Install-DockerCheck {
    Write-Host "  [Step 2 of 6] Checking Docker Desktop..." -ForegroundColor Magenta

    if (-not (Test-DockerInstalled)) {
        Write-Host "  [✗] Docker is not installed." -ForegroundColor Red
        Write-Host "      Download and install Docker Desktop:" -ForegroundColor Yellow
        Write-Host "      https://www.docker.com/products/docker-desktop/" -ForegroundColor Gray
        Write-Host "      After installing, re-run this script." -ForegroundColor Yellow
        Read-Host "  Press ENTER to return to the menu"
        return $false
    }

    if (Test-DockerRunning) {
        Write-Host "  [✓] Docker Desktop is running" -ForegroundColor Green
        return $true
    }

    Write-Host "  [*] Docker is installed but not running." -ForegroundColor Yellow
    for ($i = 1; $i -le 5; $i++) {
        Write-Host "  [Attempt $i of 5] Please start Docker Desktop, then press ENTER when ready..." -ForegroundColor Cyan
        Read-Host | Out-Null
        if (Test-DockerRunning) {
            Write-Host "  [✓] Docker Desktop is now running" -ForegroundColor Green
            return $true
        }
    }
    Write-Host "  [✗] Docker Desktop did not start successfully." -ForegroundColor Red
    Write-Host "      Please troubleshoot Docker Desktop startup manually." -ForegroundColor Yellow
    Read-Host "  Press ENTER to return to the menu"
    return $false
}

function Install-Git {
    Write-Host "  [Step 3 of 6] Checking Git..." -ForegroundColor Magenta

    $gitTest = git --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $script:gitExe = "git"
        Write-Host "  [✓] Git found: $gitTest" -ForegroundColor Green
        return $true
    }

    Write-Host "  [*] Git not found. Downloading portable Git..." -ForegroundColor Yellow

    $script:gitTempDir = "$env:TEMP\landis-git-portable\$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $gitTempDir | Out-Null

    $portableUrl = "https://github.com/git-for-windows/git/releases/download/v2.47.1.2.windows.1/PortableGit-2.47.1.2-64-bit.7z.exe"
    $portableFile = "$gitTempDir\PortableGit-2.47.1.2-64-bit.7z.exe"

    try {
        Invoke-WebRequest -Uri $portableUrl -OutFile $portableFile -UseBasicParsing -ErrorAction Stop
        Start-Process -FilePath $portableFile -ArgumentList "-o$gitTempDir -y" -Wait
    } catch {
        Write-Host "  [✗] Failed to download portable Git." -ForegroundColor Red
        Write-Host "      Install Git manually and re-run:" -ForegroundColor Yellow
        Write-Host "      https://git-scm.com/download/win" -ForegroundColor Gray
        Read-Host "  Press ENTER to return to the menu"
        return $false
    }

    $candidates = @("$gitTempDir\bin\git.exe", "$gitTempDir\cmd\git.exe", "$gitTempDir\mingw64\bin\git.exe")
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $script:gitExe = $c
            $script:portableGitInstalled = $true
            Write-Host "  [✓] Portable Git ready: $c" -ForegroundColor Green
            return $true
        }
    }

    Write-Host "  [✗] Could not locate git.exe in the portable archive." -ForegroundColor Red
    Write-Host "      Install Git manually:" -ForegroundColor Yellow
    Write-Host "      https://git-scm.com/download/win" -ForegroundColor Gray
    Read-Host "  Press ENTER to return to the menu"
    return $false
}

function Build-BaseImage {
    Write-Host "  [Step 4 of 6] Building LANDIS-II Base Image..." -ForegroundColor Magenta
    Write-Host "  This download and build may take a while." -ForegroundColor Cyan

    if (((docker image inspect $baseImage 2>&1) -and $LASTEXITCODE -eq 0)) {
        Write-Host "  [✓] Image already exists: $baseImage" -ForegroundColor Green
        Write-Host "  Rebuild anyway? (Y/N)" -ForegroundColor Yellow
        if ((Read-Host "  →") -notmatch '^[Yy]') {
            Write-Host "  Keeping the existing image." -ForegroundColor Gray
            return $true
        }
    }

    $workDir = "$repoDir\landis-base"
    if (-not (Get-GitRepo -Url 'https://github.com/LANDIS-II-Foundation/Tool-Docker-Apptainer' -Dest $workDir -Commit '4a91482c8ef39553ab9ff687b929d2ac8c071862')) {
        return $false
    }

    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = "$logDir\build-base-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    $dockerArgs = @('build', '.', '-f', 'Docker-LANDIS-II-v8-UCL2-release/Dockerfile', '--build-arg', 'UBUNTU_VERSION=26.04', '-t', $baseImage)
    Invoke-DockerBuild -WorkDir $workDir -ArgsList $dockerArgs -LogFile $logFile -Label $baseImage
    $_buildOk = Test-DockerBuild -Image $baseImage -LogFile $logFile
    return $_buildOk
}

function Build-DiverseImage {
    Write-Host "  [Step 5 of 6] Building LANDIS-II DIVERSE Image..." -ForegroundColor Magenta

    if (((docker image inspect $diverseImage 2>&1) -and $LASTEXITCODE -eq 0)) {
        Write-Host "  [✓] Image already exists: $diverseImage" -ForegroundColor Green
        Write-Host "  Rebuild anyway? (Y/N)" -ForegroundColor Yellow
        if ((Read-Host "  →") -notmatch '^[Yy]') {
            Write-Host "  Keeping the existing image." -ForegroundColor Gray
            return $true
        }
    }

    $workDir = "$repoDir\landis-diverse"
    if (-not (Get-GitRepo -Url 'https://github.com/Klemet/Docker-LANDIS-II-v8-DIVERSE' -Dest $workDir -Commit '08727e43a760370b8f6c7355f12249de24862239')) {
        return $false
    }

    $logFile = "$logDir\build-diverse-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    $dockerArgs = @('build', '.', '-t', $diverseImage)
    Invoke-DockerBuild -WorkDir $workDir -ArgsList $dockerArgs -LogFile $logFile -Label $diverseImage
    $_buildOk = Test-DockerBuild -Image $diverseImage -LogFile $logFile
    return $_buildOk
}

$launcherContent = @'
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

# Native modern "pick a folder" dialog (Win10/11 style) via IFileOpenDialog + FOS_PICKFOLDERS.
# The COM interop is done in C# (where coclass->interface casting is reliable) and exposed
# as a simple static method. Unlike the old OpenFileDialog hack, the dialog's "Select Folder"
# button always confirms the highlighted folder instead of sometimes just navigating into it.
if (-not ("NativeInterop.FolderPicker" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace NativeInterop
{
    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    public class FileOpenDialogRCW { }

    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr hwndOwner);
        [PreserveSig] int SetFileTypes(uint cFileTypes, [In] IntPtr rgFilterSpec);
        [PreserveSig] int SetFileTypeIndex(uint iFileType);
        [PreserveSig] int GetFileTypeIndex(out uint piFileType);
        [PreserveSig] int Advise([In, MarshalAs(UnmanagedType.Interface)] object pfde, out uint pdwCookie);
        [PreserveSig] int Unadvise(uint dwCookie);
        [PreserveSig] int SetOptions(uint fos);
        [PreserveSig] int GetOptions(out uint pfos);
        [PreserveSig] int SetDefaultFolder([In, MarshalAs(UnmanagedType.Interface)] object psi);
        [PreserveSig] int SetFolder([In, MarshalAs(UnmanagedType.Interface)] object psi);
        [PreserveSig] int GetFolder([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int GetCurrentSelection([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int SetFileName([In, MarshalAs(UnmanagedType.LPWStr)] string pszName);
        [PreserveSig] int GetFileName([Out, MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        [PreserveSig] int SetTitle([In, MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        [PreserveSig] int SetOkButtonLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszText);
        [PreserveSig] int SetFileNameLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        [PreserveSig] int GetResult([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int AddPlace([In, MarshalAs(UnmanagedType.Interface)] object psi, int fdap);
        [PreserveSig] int SetDefaultExtension([In, MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        [PreserveSig] int Close(int hr);
        [PreserveSig] int SetClientGuid([In] ref Guid guid);
        [PreserveSig] int ClearClientData();
        [PreserveSig] int SetFilter([In, MarshalAs(UnmanagedType.Interface)] object pFilter);
        [PreserveSig] int GetResults([MarshalAs(UnmanagedType.Interface)] out object ppenum);
        [PreserveSig] int GetSelectedItems([MarshalAs(UnmanagedType.Interface)] out object ppsai);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        [PreserveSig] int BindToHandler([In, MarshalAs(UnmanagedType.Interface)] object pbc,
            [In] ref Guid bhid, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);
        [PreserveSig] int GetParent([MarshalAs(UnmanagedType.Interface)] out object ppsi);
        [PreserveSig] int GetDisplayName(uint sigdnName, [Out, MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        [PreserveSig] int GetAttributes(ulong sfgaoMask, out ulong psfgaoAttribs);
        [PreserveSig] int Compare([In, MarshalAs(UnmanagedType.Interface)] object psi, int hint, out int piOrder);
    }

    public static class FolderPicker
    {
        const uint FOS_PICKFOLDERS     = 0x20;
        const uint FOS_FORCEFILESYSTEM = 0x40;
        const uint FOS_PATHMUSTEXIST   = 0x800;
        const uint SIGDN_FILESYSPATH   = 0x80058000;

        // Returns the selected folder path, or null if the user cancelled or an error occurred.
        public static string SelectFolder(string title)
        {
            try {
                IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogRCW();
                dlg.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
                dlg.SetTitle(title);
                dlg.SetOkButtonLabel("Select Folder");

                if (dlg.Show(IntPtr.Zero) < 0)
                    return null;   // cancelled (0x800704C7) or any other failure

                object item;
                dlg.GetResult(out item);
                IShellItem si = (IShellItem)item;

                string path;
                si.GetDisplayName(SIGDN_FILESYSPATH, out path);
                return path;
            }
            catch {
                return null;
            }
        }
    }
}
"@
}

function Select-FolderModern {
    param([string]$Title = 'Select a folder')
    return [NativeInterop.FolderPicker]::SelectFolder($Title)
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
'@

$uninstallContent = @'
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
'@

function Install-Launcher {
    Write-Host "  [Step 6 of 6] Installing the LANDIS-II Launcher..." -ForegroundColor Magenta

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null

    # Locate the package folder containing this installer's sibling .exe files.
    # When launched via the compiled .exe, the C# launcher sets LANDIS_LAUNCHER_DIR
    # to the folder that contains it; otherwise fall back to the script's folder.
    $packageDir = $env:LANDIS_LAUNCHER_DIR
    if (-not $packageDir -or -not (Test-Path -LiteralPath $packageDir)) {
        $packageDir = Split-Path -Parent $PSCommandPath
    }

    # Prefer shipping the .exe versions; fall back to the embedded .ps1 if the
    # exes aren't present (e.g. someone runs this installer .ps1 directly).
    $launcherExe   = Join-Path $packageDir "LANDIS-II-Docker-Launcher.exe"
    $uninstallExe  = Join-Path $packageDir "Uninstall-LANDIS-II-Launcher.exe"

    $launcherTarget  = $null
    $uninstallTarget = $null

    if (Test-Path -LiteralPath $launcherExe) {
        Copy-Item -Force $launcherExe "$installDir\LANDIS-II-Docker-Launcher.exe"
        $launcherTarget = "$installDir\LANDIS-II-Docker-Launcher.exe"
        Write-Host "  [✓] Launcher installed ($launcherTarget)" -ForegroundColor Green
    } else {
        Set-Content -Path "$installDir\LANDIS-II-Docker-Launcher.ps1" -Value $launcherContent -Encoding UTF8
        $launcherTarget = "$installDir\LANDIS-II-Docker-Launcher.ps1"
        Write-Host "  [✓] Launcher installed (embedded .ps1)" -ForegroundColor Green
    }

    if (Test-Path -LiteralPath $uninstallExe) {
        Copy-Item -Force $uninstallExe "$installDir\Uninstall-LANDIS-II-Launcher.exe"
        $uninstallTarget = "$installDir\Uninstall-LANDIS-II-Launcher.exe"
        Write-Host "  [✓] Uninstaller installed ($uninstallTarget)" -ForegroundColor Green
    } else {
        Set-Content -Path "$installDir\Uninstall-LANDIS-II-Launcher.ps1" -Value $uninstallContent -Encoding UTF8
        $uninstallTarget = "$installDir\Uninstall-LANDIS-II-Launcher.ps1"
        Write-Host "  [✓] Uninstaller installed (embedded .ps1)" -ForegroundColor Green
    }

    # Start Menu shortcuts (all users)
    New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
    $WshShell = New-Object -ComObject WScript.Shell

    $shortcut = $WshShell.CreateShortcut("$shortcutDir\LANDIS-II Docker Launcher.lnk")
    if ($launcherTarget -like '*.exe') {
        $shortcut.TargetPath = $launcherTarget
        $shortcut.IconLocation = "$launcherTarget,0"
    } else {
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$launcherTarget`""
        $shortcut.IconLocation = "powershell.exe,0"
    }
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Save()

    $uninstallShortcut = $WshShell.CreateShortcut("$shortcutDir\Uninstall LANDIS-II Docker Launcher.lnk")
    if ($uninstallTarget -like '*.exe') {
        $uninstallShortcut.TargetPath = $uninstallTarget
        $uninstallShortcut.IconLocation = "$uninstallTarget,0"
    } else {
        $uninstallShortcut.TargetPath = "powershell.exe"
        $uninstallShortcut.Arguments = "-ExecutionPolicy Bypass -File `"$uninstallTarget`""
        $uninstallShortcut.IconLocation = "powershell.exe,0"
    }
    $uninstallShortcut.WorkingDirectory = $installDir
    $uninstallShortcut.Save()

    Remove-Item -Force $sentinel -ErrorAction SilentlyContinue
    Write-Host "  [✓] Start Menu shortcuts created" -ForegroundColor Green
    Write-Host "  [✓] Launcher installed to $installDir" -ForegroundColor Green
}

function Invoke-Install {
    if (-not (Install-Wsl)) { Write-Host "  Installation aborted." -ForegroundColor Red; Pause-Prompt; return }
    if (-not (Install-DockerCheck)) { Write-Host "  Installation aborted." -ForegroundColor Red; Pause-Prompt; return }
    if (-not (Install-Git)) { Write-Host "  Installation aborted." -ForegroundColor Red; Pause-Prompt; return }
    if (-not (Build-BaseImage)) { Write-Host "  Installation aborted at the base image step." -ForegroundColor Red; Pause-Prompt; return }
    if (-not (Build-DiverseImage)) { Write-Host "  Installation aborted at the DIVERSE image step." -ForegroundColor Red; Pause-Prompt; return }
    Install-Launcher

    Show-Header
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "        LANDIS-II INSTALLATION COMPLETE" -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Summary:" -ForegroundColor Cyan
    Write-Host "    Base image:    $baseImage" -ForegroundColor White
    Write-Host "    DIVERSE image: $diverseImage" -ForegroundColor White
    Write-Host "    Launcher:      $installDir" -ForegroundColor White
    Write-Host "    Shortcut:      $shortcutDir\LANDIS-II Docker Launcher.lnk" -ForegroundColor White
    Write-Host "    Logs:          $logDir" -ForegroundColor White
    Write-Host ""
    if ($portableGitInstalled) {
        Write-Host "  Note: Portable Git used for installation and cleaned up." -ForegroundColor Yellow
    }
    Pause-Prompt
}

# ==== UNINSTALL FLOW ==========================================================

function Invoke-UninstallAll {
    Invoke-UninstallLauncher
    Invoke-UninstallDocker
    Invoke-UninstallWsl
    Write-Host "  All removal operations finished. Review messages above." -ForegroundColor Yellow
    Pause-Prompt
}

function Invoke-UninstallWsl {
    Write-Host ""
    Write-Host "  WARNING:" -ForegroundColor Red
    Write-Host "  This will unregister ALL WSL2 Linux distributions and disable WSL2." -ForegroundColor Red
    Write-Host "  You will lose ALL Linux packages, files, and configurations." -ForegroundColor Red
    $answer = Read-Host "  Are you sure? (Y/N)"
    if ($answer -notmatch '^[Yy]') { return }

    $ok = $true
    $distros = wsl --list --verbose 2>&1
    if ($LASTEXITCODE -eq 0 -and $distros) {
        foreach ($line in $distros | Select-Object -Skip 3) {
            $name = ($line -split '\s+')[1]
            if ($name -and $name -notmatch 'NAME|WSL|<') {
                Write-Host "  Unregistering: $name" -ForegroundColor Cyan
                wsl --unregister $name 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { $ok = $false }
            }
        }
    }

    Write-Host "  Disable the Microsoft-Windows-Subsystem-Linux feature? (Y/N)" -ForegroundColor Yellow
    if ((Read-Host "  →") -match '^[Yy]') {
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart -ErrorAction Stop | Out-Null
            Write-Host "  [✓] WSL feature disabled (restart may be required)" -ForegroundColor Green
        } catch {
            $ok = $false
            Write-Host "  [✗] Could not disable the feature." -ForegroundColor Red
        }
    }

    if (-not $ok) {
        Write-Host "  Some WSL removal steps failed." -ForegroundColor Yellow
        Write-Host "  Manual steps: Control Panel -> Programs -> Turn Windows features on/off -> disable WSL." -ForegroundColor Gray
    } else {
        Write-Host "  [✓] WSL removal completed" -ForegroundColor Green
    }
}

function Invoke-UninstallDocker {
    Write-Host ""
    Write-Host "  WARNING:" -ForegroundColor Red
    Write-Host "  This will uninstall Docker Desktop." -ForegroundColor Red
    Write-Host "  You will lose ALL Docker images, containers, volumes, and configurations." -ForegroundColor Red
    $answer = Read-Host "  Are you sure? (Y/N)"
    if ($answer -notmatch '^[Yy]') { return }

    $ok = $true
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "  Uninstalling via winget..." -ForegroundColor Cyan
        winget uninstall Docker.DockerDesktop 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $false; Write-Host "  [✓] Docker Desktop removed via winget" -ForegroundColor Green }
    }

    if ($ok) {
        $installer = "$env:LOCALAPPDATA\Docker\Docker Desktop Installer.exe"
        if (Test-Path $installer) {
            Write-Host "  Uninstalling via Docker installer..." -ForegroundColor Cyan
            & $installer uninstall 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [✓] Docker Desktop removal initiated" -ForegroundColor Green
                $ok = $false
            }
        }
    }

    if ($ok) {
        Write-Host "  [✗] Automatic uninstall failed." -ForegroundColor Red
        Write-Host "  Please uninstall manually: Windows Settings -> Apps -> Installed Apps -> Docker Desktop -> Uninstall." -ForegroundColor Yellow
    }

    Write-Host "  Note: Docker data directories may persist after uninstall:" -ForegroundColor Yellow
    Write-Host "    $env:LOCALAPPDATA\Docker" -ForegroundColor Gray
    Write-Host "    $env:APPDATA\Docker" -ForegroundColor Gray
    Write-Host "    C:\ProgramData\Docker" -ForegroundColor Gray
}

function Invoke-UninstallLauncher {
    Write-Host ""
    Write-Host "  Removing LANDIS-II Docker Launcher..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $shortcutDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$env:LOCALAPPDATA\LANDIS-II-Docker" -ErrorAction SilentlyContinue
    Write-Host "  [✓] Launcher and related data removed" -ForegroundColor Green
}

function Invoke-Uninstall {
    Show-Header
    Write-Host "  What would you like to remove?" -ForegroundColor Yellow
    $options = @(
        "[1] Remove ALL (WSL2 + Docker Desktop + LANDIS-II Docker Launcher)",
        "[2] Remove WSL2 only",
        "[3] Remove Docker Desktop only",
        "[4] Remove LANDIS-II Docker Launcher only",
        "[5] Back to main menu"
    )
    $choice = Show-Menu -Title "UNINSTALL" -Options $options
    switch ($choice) {
        0 { Invoke-UninstallAll }
        1 { Invoke-UninstallWsl }
        2 { Invoke-UninstallDocker }
        3 { Invoke-UninstallLauncher }
        4 { return }
    }
}

# ==== APPTAINER FLOW ==========================================================

function Invoke-Apptainer {
    Show-Header
    Write-Host "  APPTAINER" -ForegroundColor Yellow

    docker image inspect $diverseImage 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [✗] The Docker image '$diverseImage' does not exist." -ForegroundColor Red
        Write-Host "      Please run the INSTALL step first." -ForegroundColor Yellow
        Pause-Prompt
        return
    }

    Write-Host ""
    Write-Host "  WARNING:" -ForegroundColor Red
    Write-Host "  This operation requires approximately 4-8 GB of free RAM." -ForegroundColor Red
    Write-Host "  If your computer does not have enough available RAM, the process will CRASH." -ForegroundColor Red
    Write-Host "  Close other applications before proceeding." -ForegroundColor Red
    if ((Read-Host "  Continue? (Y/N)") -notmatch '^[Yy]') { return }

    $OUTPUT_FOLDER = Select-FolderModern -Title "Select the output folder for the .sif file"
    if (-not $OUTPUT_FOLDER) {
        Write-Host "  [*] Cancelled." -ForegroundColor Gray
        return
    }
    if (-not (Test-Path $OUTPUT_FOLDER)) {
        Write-Host "  [✗] Output folder does not exist." -ForegroundColor Red
        return
    }

    Write-Host "  Building Apptainer image (this may take a while)..." -ForegroundColor Cyan
    docker run --rm `
        -e APPTAINER_MKSQUASHFS_MEM=1G `
        -e APPTAINER_MKSQUASHFS_PROCS=4 `
        -v /var/run/docker.sock:/var/run/docker.sock `
        -v "${OUTPUT_FOLDER}:/work" `
        -w /work `
        kaczmarj/apptainer `
        build landis-ii-v8-uclv2-diverse.sif docker-daemon://landis-ii-v8-uclv2-diverse:latest
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [✗] Apptainer build failed." -ForegroundColor Red
        Write-Host "      Check RAM (close other applications), Docker logs, and retry." -ForegroundColor Yellow
        Pause-Prompt
        return
    }

    $sifPath = Join-Path $OUTPUT_FOLDER "landis-ii-v8-uclv2-diverse.sif"
    if (Test-Path $sifPath) {
        $size = (Get-Item $sifPath).Length
        if ($size -gt 0) {
            Write-Host "  [✓] Apptainer image created successfully!" -ForegroundColor Green
            Write-Host "  Location: $sifPath" -ForegroundColor Green
            Write-Host "  Size: $([math]::Round($size / 1MB, 2)) MB" -ForegroundColor Green
        } else {
            Write-Host "  [✗] .sif file is empty. The build likely failed." -ForegroundColor Red
        }
    } else {
        Write-Host "  [✗] .sif file was not created. Check Docker logs for details." -ForegroundColor Red
    }
    Pause-Prompt
}

# ==== MAIN LOOP ===============================================================

function Show-MainMenu {
    Show-Header
    Write-Host "  Main Menu" -ForegroundColor Yellow
    $options = @(
        "[1] INSTALL LANDIS-II DOCKER",
        "[2] UNINSTALL",
        "[3] (OPTIONAL) CREATE APPTAINER",
        "[4] Exit"
    )
    $choice = Show-Menu -Title "MAIN MENU" -Options $options
    switch ($choice) {
        0 {
            Show-Header
            Test-Environment
            try { Invoke-Install } finally {}
        }
        1 { Invoke-Uninstall }
        2 { Invoke-Apptainer }
        3 { exit }
    }
}

# == Entry point ==
try {
    while ($true) {
        Show-MainMenu
    }
} finally {
    if ($portableGitInstalled -and $gitTempDir -and (Test-Path $gitTempDir)) {
        Remove-Item -Recurse -Force $gitTempDir -ErrorAction SilentlyContinue
    }
}
