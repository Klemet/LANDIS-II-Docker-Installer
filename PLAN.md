# PLAN — LANDIS-II Docker Install Script for Windows

## Overview

A PowerShell script to install, run, and manage the LANDIS-II Forest Landscape Model via Docker on Windows. The script automates WSL2 setup, Docker Desktop verification, two-stage Docker image builds from pinned GitHub commits, and provides a user-friendly launcher for running simulations.

---

## Files to Create

| File | Purpose |
|---|---|
| `install-landis-ii.ps1` | Main script (must be run as admin) |
| `LANDIS-II-Docker-Launcher.ps1` | Installed into `Program Files`, used by end-users to launch simulations via an Explorer GUI |
| `Uninstall-LANDIS-II-Launcher.ps1` | Installed alongside the launcher, removes only the launcher and its Start Menu shortcut |

---

## 1. Script Startup & Admin Check

### 1.1 Privilege elevation
- Check if running as administrator using:
  ```powershell
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  ```
- If **not admin**: display a red error explaining that elevated privileges are required (especially critical for government/restricted machines), then auto-elevate via `Start-Process -Verb RunAs -FilePath powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""` and exit the current instance.

### 1.2 Header & branding
- Clear the console.
- Display a boxed ASCII-art header: `LANDIS-II Docker Installer` with version info.

### 1.3 Restricted environment detection
- **DNS check**: Attempt `Resolve-DnsName github.com` — if it fails, warn the user about potential network restrictions (firewall, VPN, proxy) which will prevent cloning repos and pulling Docker images.
- **Execution policy**: Check `Get-ExecutionPolicy` — if `Restricted`, attempt `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`. If that fails, warn the user they may need to adjust policies (common on government machines).
- **AppLocker check**: Query `Get-AppLockerPolicy -Effective` (if the module is available) — if rules exist, warn that execution from temp directories may be blocked.
- **Free disk space**: Check at least 10 GB available on the system drive before proceeding.

### 1.4 Sentinel file for post-reboot continuation
- Path: `$env:LOCALAPPDATA\LANDIS-II-Docker\sentinel`
- After enabling Windows features, write a sentinel indicating which step to resume from.
- On script start, check for sentinel; if present, skip already-completed checks and resume.

---

## 2. Arrow-Key Menu System

Custom implementation using `[Console]::ReadKey($true)` in a loop:

### 2.1 Rendering
- Render options with a `>` cursor that moves with **Up** (`[ConsoleKey]::UpArrow`) and **Down** (`[ConsoleKey]::DownArrow`) arrows.
- Selected option highlighted in **Cyan**; others in **White**.
- **Enter** (`[ConsoleKey]::Enter`) to confirm.
- Display `[↑↓] Navigate  [ENTER] Select` hint at the bottom.

### 2.2 Main Menu Options
```
  [1] INSTALL LANDIS-II DOCKER
  [2] UNINSTALL
  [3] (OPTIONAL) CREATE APPTAINER
  [4] Exit
```

---

## 3. INSTALL Flow

### 3.1 WSL2 Check & Install

```
wsl.exe exists? AND wsl --status succeeds?
├── YES → skip to Docker check (Section 3.2)
└── NO → check Windows features
    ├── Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux"
    ├── Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform"
    ├── If either State ≠ Enabled:
    │   ├── Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart
    │   ├── Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -NoRestart
    │   ├── Write sentinel file
    │   ├── Display: "A REBOOT IS REQUIRED. Please restart your computer, then re-run this script."
    │   └── Exit
    └── After reboot (features enabled) → run wsl --install or wsl --update
        ├── Success → continue
        └── Fail → point to https://learn.microsoft.com/en-us/windows/wsl/install
            → Exit
```

**Key details:**
- Use `Get-WindowsOptionalFeature -Online` to check feature state.
- Use `Enable-WindowsOptionalFeature -Online -NoRestart` (no automatic reboot).
- The sentinel file encodes which step was reached before the reboot.
- On re-run after reboot, the script sees features are now enabled and proceeds to `wsl --install` (Windows 11) or `wsl --update` + `wsl --set-default-version 2` (Windows 10).
- If `wsl --install` fails entirely, the user's Windows build may be too old — direct them to the Microsoft WSL documentation.

### 3.2 Docker Desktop Check

```
Try: docker info 2>&1
├── Returns version info (exit code 0)
│   → Docker is running → continue to Section 3.3
├── Command not found / "not recognized"
│   → Docker not installed
│   → Display URL: https://www.docker.com/products/docker-desktop/
│   → Instructions: download, install Docker Desktop, then re-run this script
│   → Exit
└── "failed to connect" / "docker daemon is not running" / connection errors
    → Docker installed but not running
    → Loop (max 5 retries):
        ├── Tell user: "Please start Docker Desktop, then press ENTER when ready"
        ├── Wait for keypress
        ├── Retry: docker info 2>&1
        └── On success → break
    → If all retries exhausted → error, suggest manual Docker Desktop startup troubleshooting
```

**Key details:**
- Distinguish between "not installed" (executable missing) vs. "installed but not running" (daemon error).
- Give the user clear, actionable instructions for both cases.
- Avoid silent waiting — always prompt the user before retrying.

### 3.3 Git Check (Portable if Needed)

```
Try: git --version 2>&1
├── Success → use system git ($gitExe = "git")
└── Fail → download portable Git
    ├── Temp folder: $env:TEMP\landis-git-portable\<timestamp>\
    ├── Download portable Git archive (e.g., PortableGit-2.47.1.2-64-bit.7z.exe)
    │   from https://github.com/git-for-windows/git/releases
    ├── Self-extract (the .7z.exe is a self-extracting archive)
    ├── Locate git.exe: <extract>\bin\git.exe (or <extract>\cmd\git.exe)
    ├── Set $gitExe = "<full path to git.exe>"
    └── Mark for cleanup: $portableGitInstalled = $true
```

**Cleanup (script exit, success or failure):**
```powershell
if ($portableGitInstalled) {
    Remove-Item -Recurse -Force $gitTempDir -ErrorAction SilentlyContinue
}
```

### 3.4 First Docker Build — LANDIS-II Base Image

#### 3.4.1 Clone repository
```powershell
$workDir = "$env:LOCALAPPDATA\LANDIS-II-Docker\repos"
New-Item -ItemType Directory -Force -Path "$workDir\landis-base"

& $gitExe clone https://github.com/LANDIS-II-Foundation/Tool-Docker-Apptainer "$workDir\landis-base"
Set-Location "$workDir\landis-base"
& $gitExe checkout 043b43e6291813d5092721d45ff630502e777e30
```

#### 3.4.2 Build
```powershell
$logDir = "$env:LOCALAPPDATA\LANDIS-II-Docker\logs"
New-Item -ItemType Directory -Force -Path $logDir
$logFile = "$logDir\build-base-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

docker build . `
  -f Docker-LANDIS-II-v8-UCL2-release/Dockerfile `
  --build-arg UBUNTU_VERSION=26.04 `
  -t landis-ii-v8-uclv2-release:ubuntu-26.04 `
  2>&1 | Tee-Object -FilePath $logFile
```

#### 3.4.3 Post-build verification
- Check `$LASTEXITCODE` (not `$?` — `$?` only checks the last PowerShell command, not external executables).
- If `$LASTEXITCODE -eq 0`: verify image exists with `docker image inspect landis-ii-v8-uclv2-release:ubuntu-26.04`.
- If `$LASTEXITCODE -ne 0`: parse the log file for error categories.

#### 3.4.4 Error categorization
| Pattern | Category | Advice to user |
|---|---|---|
| `SSL`, `certificate`, `TLS`, `The remote name could not be resolved` | Network/SSL error | Check proxy settings, firewall rules, VPN. Corporate networks may block Docker Hub or GitHub. |
| `Could not resolve host`, `Connection refused`, `timed out`, `Name or service not known` | Connection error | Check internet connectivity. Docker daemon may not have network access. Restart Docker Desktop. |
| `error CS`, `MSB`, `dotnet build`, `Build FAILED`, `error : ` (NuGet) | .NET compilation error | Extension version incompatibility. A LANDIS-II extension may have changed its repository or version. |
| `returned a non-zero code`, `The command '/bin/sh -c' returned` | Dockerfile step failure | A RUN command in the Dockerfile failed. Check the log for the specific step. |
| Default (none of the above) | Unknown error | General build failure. |

**For all failures:**
- Display the log file path prominently.
- Provide a link to the GitHub issue tracker.
- Suggest the user attach the log file when reporting.

### 3.5 Second Docker Build — DIVERSE Image

```powershell
& $gitExe clone https://github.com/Klemet/Docker-LANDIS-II-v8-DIVERSE "$workDir\landis-diverse"
Set-Location "$workDir\landis-diverse"
& $gitExe checkout 0953f5809bd483ec23a8e5a1f1f8878da6efc408

$logFile = "$logDir\build-diverse-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

docker build . `
  -t landis-ii-v8-uclv2-diverse `
  2>&1 | Tee-Object -FilePath $logFile
```

- Same post-build verification and error categorization as Section 3.4.
- This Dockerfile uses `FROM landis-ii-v8-uclv2-release:ubuntu-26.04` as its base — no need to verify this, it's designed that way.

### 3.6 Install Launcher Program

#### 3.6.1 Create installation directory
```powershell
$installDir = "C:\Program Files\LANDIS-II Docker Launcher"
New-Item -ItemType Directory -Force -Path $installDir
```

#### 3.6.2 Write launcher script
Write `LANDIS-II-Docker-Launcher.ps1` to `$installDir` (see Section 4).

#### 3.6.3 Write uninstall script
Write `Uninstall-LANDIS-II-Launcher.ps1` to `$installDir` (see Section 5).

#### 3.6.4 Create Start Menu shortcut
```powershell
$shortcutDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\LANDIS-II Docker Launcher"
New-Item -ItemType Directory -Force -Path $shortcutDir

$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut("$shortcutDir\LANDIS-II Docker Launcher.lnk")
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = '-ExecutionPolicy Bypass -File "C:\Program Files\LANDIS-II Docker Launcher\LANDIS-II-Docker-Launcher.ps1"'
$shortcut.WorkingDirectory = "C:\Program Files\LANDIS-II Docker Launcher"
$shortcut.IconLocation = "powershell.exe,0"
$shortcut.Save()
```

- Uses `$env:ProgramData` so the shortcut appears for **all users** on the machine.

### 3.7 Cleanup
- Delete portable Git temp folder (if used).
- Delete the sentinel file.
- Optionally delete cloned repos (`$workDir\repos\`) — or leave them for user inspection.
- Display success message with a summary of what was installed and where.

---

## 4. Launcher Script (`LANDIS-II-Docker-Launcher.ps1`)

### 4.1 Purpose
A user-friendly script that lets the user select a simulation folder and scenario file via Windows Explorer popups, then runs the LANDIS-II simulation in Docker.

### 4.2 Flow

```
1. Display header: "LANDIS-II Docker Launcher"
2. Check if Docker is running (docker info) — if not, warn and exit
3. Check if the Docker image exists (docker image inspect) — if not, warn and exit
4. Open FolderBrowserDialog → user selects SIMULATION_FOLDER
   → If cancelled → exit
5. Open OpenFileDialog (initial directory = SIMULATION_FOLDER) → user selects scenario .txt file
   → If cancelled → exit
6. Derive:
   - scenarioFolder = parent directory of the selected file
   - relativeFolder = scenarioFolder relative to SIMULATION_FOLDER
   - scenarioName = filename of the selected file
7. Construct and execute docker run command
8. Pause (so the user can read output before the window closes)
```

### 4.3 Path derivation logic
```powershell
$SIMULATION_FOLDER = $folderBrowser.SelectedPath          # e.g., C:\Users\...\MySimulation
$SCENARIO_FILE = $fileBrowser.FileName                     # e.g., C:\Users\...\MySimulation\scenarios\scenario.txt

$scenarioFolder = Split-Path $SCENARIO_FILE -Parent        # e.g., C:\Users\...\MySimulation\scenarios
$scenarioName = Split-Path $SCENARIO_FILE -Leaf             # e.g., scenario.txt

$relativeFolder = $scenarioFolder.Replace($SIMULATION_FOLDER, '').TrimStart('\', '/')  # e.g., "scenarios"

# If the file is at the root of SIMULATION_FOLDER, $relativeFolder is empty
$subfolderCd = if ($relativeFolder) {
    "cd /scenarioFolder/$($relativeFolder.Replace('\', '/')) && "
} else {
    ''
}
```

### 4.4 Docker command construction
```powershell
$dockerCmd = @"
docker run --rm --mount type=bind,src="$SIMULATION_FOLDER",dst=/scenarioFolder landis-ii-v8-uclv2-diverse /bin/sh -c "${subfolderCd}dotnet `$LANDIS_CONSOLE "$scenarioName""
"@

Write-Host "`nRunning simulation..." -ForegroundColor Cyan
Write-Host "Simulation folder: $SIMULATION_FOLDER" -ForegroundColor Gray
Write-Host "Scenario file: $scenarioName" -ForegroundColor Gray
Write-Host "---" -ForegroundColor Gray
Invoke-Expression $dockerCmd
```

**Key details:**
- `$LANDIS_CONSOLE` is an environment variable inside the Docker image that points to the LANDIS-II console executable.
- The `$` in `$LANDIS_CONSOLE` must be escaped as `` `$ `` in the PowerShell here-string so Docker receives the literal `$LANDIS_CONSOLE` for Bash to expand.
- Paths with spaces are handled by quoting `$SIMULATION_FOLDER` and `$scenarioName`.
- `pause` at the end keeps the console window open.

---

## 5. Uninstall Script (Installed Alongside Launcher)

```powershell
$installDir = "C:\Program Files\LANDIS-II Docker Launcher"
$shortcutDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\LANDIS-II Docker Launcher"

Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $shortcutDir -ErrorAction SilentlyContinue

Write-Host "LANDIS-II Docker Launcher has been uninstalled." -ForegroundColor Green
pause
```

---

## 6. UNINSTALL Flow (Main Script)

### 6.1 Sub-menu
Arrow-key menu with four options + back:

```
  [1] Remove ALL (WSL2 + Docker Desktop + LANDIS-II Docker Launcher)
  [2] Remove WSL2 only
  [3] Remove Docker Desktop only
  [4] Remove LANDIS-II Docker Launcher only
  [5] Back to main menu
```

### 6.2 Remove ALL
Execute steps 6.3, 6.4, 6.5 in sequence. Do not abort if one step fails — continue to the next and report all successes/failures at the end.

### 6.3 Remove WSL2
1. **BIG WARNING**: "This will unregister ALL WSL2 Linux distributions and disable WSL2. You will lose ALL Linux packages, files, and configurations. Are you sure? (Y/N)"
2. If confirmed:
   - `wsl --list --verbose` to enumerate distributions.
   - For each distribution: `wsl --unregister <distro>`.
   - Then disable Windows features (optional, ask user):
     - `Disable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart`
   - If any step fails, give manual uninstall instructions.

### 6.4 Remove Docker Desktop
1. **BIG WARNING**: "This will uninstall Docker Desktop. You will lose ALL Docker images, containers, volumes, and configurations. Are you sure? (Y/N)"
2. If confirmed:
   - Try: `winget uninstall Docker.DockerDesktop` (or `"Docker Desktop"` depending on winget ID).
   - If winget fails or is unavailable, try the uninstaller: `& "$env:LOCALAPPDATA\Docker\Docker Desktop Installer.exe" uninstall`.
   - If that also fails, point the user to: Windows Settings → Apps → Installed Apps → Docker Desktop → Uninstall.
   - Note: Docker data directories (`$env:LOCALAPPDATA\Docker`, `$env:APPDATA\Docker`, `C:\ProgramData\Docker`) may persist after uninstall. Inform the user.

### 6.5 Remove LANDIS-II Docker Launcher
Same as the standalone uninstall script (Section 5). Also clean up:
- `$env:LOCALAPPDATA\LANDIS-II-Docker\` (logs, repos, sentinel).

---

## 7. APPTAINER Flow

### 7.1 Entry
- Check that the Docker image `landis-ii-v8-uclv2-diverse:latest` exists (via `docker image inspect`). If not, tell the user to run the INSTALL step first.

### 7.2 RAM warning
- Display a clear warning:
  ```
  This operation requires approximately 4-8 GB of free RAM.
  If your computer does not have enough available RAM, the process will CRASH.
  Close other applications before proceeding.
  ```
- Ask for confirmation: `Continue? (Y/N)`

### 7.3 Select output folder
- Use `[System.Windows.Forms.FolderBrowserDialog]` to let the user pick the output folder.
- Validate the folder exists and is writable.
- The `.sif` file will be created at: `<OUTPUT_FOLDER>\landis-ii-v8-uclv2-diverse.sif`

### 7.4 Build
```powershell
docker run --rm `
  -e APPTAINER_MKSQUASHFS_MEM=1G `
  -e APPTAINER_MKSQUASHFS_PROCS=4 `
  -v /var/run/docker.sock:/var/run/docker.sock `
  -v "$OUTPUT_FOLDER:/work" `
  -w /work `
  kaczmarj/apptainer `
  build landis-ii-v8-uclv2-diverse.sif docker-daemon://landis-ii-v8-uclv2-diverse:latest
```

**Key details:**
- `-v "$OUTPUT_FOLDER:/work"` + `-w /work`: The container's working directory is `/work`, which is a bind mount to the user's output folder. The `.sif` file will land directly in the user's chosen location.
- `-v /var/run/docker.sock:/var/run/docker.sock`: Gives Apptainer inside the container access to the host's Docker daemon so it can convert the Docker image.
- `APPTAINER_MKSQUASHFS_MEM=1G` limits squashfs memory usage.
- `APPTAINER_MKSQUASHFS_PROCS=4` limits CPU usage.

### 7.5 Verify
```powershell
$sifPath = Join-Path $OUTPUT_FOLDER "landis-ii-v8-uclv2-diverse.sif"
if (Test-Path $sifPath) {
    $size = (Get-Item $sifPath).Length
    if ($size -gt 0) {
        Write-Host "Apptainer image created successfully!" -ForegroundColor Green
        Write-Host "Location: $sifPath" -ForegroundColor Green
        Write-Host "Size: $([math]::Round($size / 1MB, 2)) MB" -ForegroundColor Green
    } else {
        Write-Host "Error: .sif file is empty. The build likely failed." -ForegroundColor Red
    }
} else {
    Write-Host "Error: .sif file was not created. Check Docker logs for details." -ForegroundColor Red
}
```

---

## 8. Error Handling Strategy

| Scenario | Behavior |
|---|---|
| Not running as admin | Auto-elevate and re-launch |
| ExecutionPolicy Restricted | Attempt `Bypass` for current process; if blocked, warn user |
| Network unreachable (DNS fails) | Warn about firewall/proxy/VPN; suggest manual steps; offer to continue anyway |
| WSL feature enable fails | Show exact error; suggest manual `dism` commands |
| `wsl --install` fails | Point to Microsoft WSL documentation |
| Docker Desktop not installed | Provide download URL; exit |
| Docker Desktop not running | Retry loop with user prompts (max 5 retries) |
| Docker build fails | Parse log, categorize error, give tailored advice, show log path, point to issue tracker |
| Docker image missing after build | Report corruption; suggest re-running |
| Disk space low (< 10 GB) | Warn user; offer to continue anyway |
| Git download fails | Suggest manual Git installation; provide URL |
| Docker run fails (launcher) | Show the exact command for debugging; suggest checking Docker Desktop status |
| Apptainer build fails | Check RAM; suggest closing other applications; check Docker logs |
| Uninstall fails | Give manual uninstall instructions specific to the component |
| SIGTERM / Ctrl+C | Trap with `try/finally` — cleanup portable Git temp folder |

**Global `$ErrorActionPreference`**: Set to `Stop` in critical sections; use `-ErrorAction SilentlyContinue` or `try/catch` for non-fatal checks.

---

## 9. UI/UX Guidelines

### 9.1 Headers
- Boxed ASCII header at script start.
- Section headers with `---` separators between major steps.

### 9.2 Colors
| Color | Usage |
|---|---|
| `Cyan` | Headers, info messages, current step indicator, menu selection highlight |
| `Green` | Success messages, checkmarks (`[✓]`) |
| `Yellow` | Warnings, prompts |
| `Red` | Errors, failures (`[✗]`) |
| `White` | Normal text, menu items |
| `Gray` / `DarkGray` | Secondary info, file paths |
| `Magenta` | Step counters (e.g., `[Step 1 of 6]`) |

### 9.3 Spacing
- Blank line before each major section.
- Blank line after each completed step.

### 9.4 Progress
- Show `[Step X of Y]` during the INSTALL flow.
- Show a brief description of what's happening before each long-running operation.

### 9.5 Consistency
- All "Press ENTER to continue..." prompts use the same format.
- All success/failure messages use the same format with `[✓]` / `[✗]` prefixes.

---

## 10. Directory Structure Summary

```
$env:LOCALAPPDATA\LANDIS-II-Docker\
├── sentinel                              # Post-reboot sentinel file (temporary)
├── logs\
│   ├── build-base-YYYYMMDD-HHmmss.log    # First Docker build log
│   └── build-diverse-YYYYMMDD-HHmmss.log # Second Docker build log
└── repos\                                # Temp cloned repositories (cleaned up after install)
    ├── landis-base\
    └── landis-diverse\

C:\Program Files\LANDIS-II Docker Launcher\
├── LANDIS-II-Docker-Launcher.ps1         # Simulation launcher script
└── Uninstall-LANDIS-II-Launcher.ps1      # Standalone uninstaller for the launcher

$env:ProgramData\Microsoft\Windows\Start Menu\Programs\LANDIS-II Docker Launcher\
└── LANDIS-II Docker Launcher.lnk          # Shortcut for all users
```

---

## 11. Edge Cases Handled

| Edge Case | Handling |
|---|---|
| Script interrupted mid-install | Sentinel file + re-entrant design. Each step checks if its prerequisite is already done. |
| Docker Desktop takes >60s to start | Retry loop (max 5) with user prompts between attempts. |
| Scenario file at nested path inside simulation folder | Relative `cd` derivation from the mount point. |
| Scenario file at root of simulation folder | No `cd` prefix added to the Docker command. |
| Paths with spaces in simulation folder or scenario file | Proper quoting throughout all `docker run` commands. |
| User cancels folder/file picker | Graceful exit with a message. |
| WSL2 already installed | Skip feature enable, go straight to Docker check. |
| Both Docker images already exist | Skip builds (or ask user: "Image already exists. Rebuild?") |
| `winget` not available for Docker uninstall | Fallback to App Installer path or manual instructions. |
| Government/restricted environments | Early detection (execution policy, AppLocker, network) + clear messaging. |
| PowerShell console closes immediately on error | `pause` at strategic points; `Read-Host` before exit on error. |
| Running on non-English Windows | Use culture-invariant commands; avoid localized strings in error parsing. |

---

## 12. Implementation Order

1. **Create `PLAN.md`** (done)
2. **Implement the arrow-key menu system** — reusable function
3. **Implement header/UI helper functions** — consistent styling
4. **Implement INSTALL flow** (sections 3.1 through 3.7)
5. **Implement launcher script** (section 4) — embedded as a here-string in the main script
6. **Implement uninstall launcher script** (section 5) — embedded as a here-string
7. **Implement UNINSTALL flow** (section 6)
8. **Implement APPTAINER flow** (section 7)
9. **Error handling & edge case hardening**
10. **Testing** on clean Windows VM or machine
