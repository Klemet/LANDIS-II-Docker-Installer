# LANDIS-II Docker Installer for Windows

> One-click install of the [LANDIS-II](https://landis-ii.org/) Forest Landscape Model on Windows, running entirely inside Docker — no Linux environment, no manual dependency setup, no pain.

**⚠ Currently installs the Docker image from [https://github.com/Klemet/Docker-LANDIS-II-v8-DIVERSE](https://github.com/Klemet/Docker-LANDIS-II-v8-DIVERSE). Future versions will allow for customising the image installed.**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell&logoColor=white)](#)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-0078D6?logo=windows&logoColor=white)](#)
[![Made for researchers](https://img.shields.io/badge/For-Forest%20Researchers-2ea44f)](#)

---

## What is it?

LANDIS-II is a powerful spatial simulation model of forest landscape change. But using it on Windows (or on other OSs like Linux or macOS) can lead to many errors because of incompatibilities between extensions. In addition, because every extension and support library can have a different version, replicating a given LANDIS-II environment can be very difficult. This makes replicating or sharing your research more troublesome than it should be.

Through time, the LANDIS-II community has developed Docker images to use LANDIS-II (see [Tool-Docker-Apptainer](https://github.com/LANDIS-II-Foundation/Tool-Docker-Apptainer)). Docker is a program that allows you to build "images" based on commands contained in a simple text file (called a Dockerfile); these images are virtual machines containing an OS (like Ubuntu) plus any program you want to install in it. To share your image, you just have to share your Dockerfile, making sharing and replicating your environment easy. You can then use images to run a program in the environment defined by the image (in what we call a "Docker container").

Using Docker images to run LANDIS-II has a lot of advantages. It makes your LANDIS-II environment more stable, you can benefit from curated updates of environments tested by the community from the [Tool-Docker-Apptainer](https://github.com/LANDIS-II-Foundation/Tool-Docker-Apptainer) repository, and you can share and replicate your research more easily with reviewers and colleagues.

But installing Docker and building images can require a bit of technical know-how (even though step-by-step instructions and online resources make this quite easy). Still, this project makes things even easier by giving you a single **Windows installer** that:

- ✔️ **Automatically sets up WSL2** (the Windows Subsystem for Linux) and verifies it (needed to run Docker on Windows).
- ✔️ **Checks and guides you through Docker Desktop**.
- ✔️ **Builds two LANDIS-II Docker images** from pinned GitHub commits (reproducible, doesn't change with time or updates).
- ✔️ **Installs a friendly launcher** with a Start Menu shortcut and a real Windows Explorer "pick a folder" dialog.
- ✔️ **Handles government/restricted machines** — it proactively detects execution-policy, AppLocker, and network restrictions with clear guidance.
- ✔️ **Can also produce an Apptainer (`.sif`)** image for HPC clusters.

The result: you can install a dockerized version of LANDIS-II easily on your machine and run simulations easily.

> Built by Clément Hardy, PhD., with the help of AI models 🤖. Designed for forest ecologists, students, and anyone who just wants to use LANDIS-II with the benefits of Docker (more replicable, usable on supercomputing clusters, etc.).

---

## Will this remove/edit my current regular LANDIS-II installation?

If you have a "regular" installation of LANDIS-II on your Windows computer (i.e., LANDIS-II installed according to the instructions on the [LANDIS-II website](https://www.landis-ii.org/), using a separate `.exe` installer), then **be reassured that installing the dockerized version of LANDIS-II will not impact your regular LANDIS-II installation at all**.

The dockerized version of LANDIS-II (the Docker image containing it) will be located in a hard drive file used by Docker (a .ext4 or .vhdx file most likely located in `C:/Users/{your user name}/AppData/Local/Docker/wsl/disk`) which emulates a Linux hard drive. Meanwhile, your regular LANDIS-II installation will still be at `C:/Program Files/LANDIS-II v8`.

The dockerized version will also not interfere with how you are used to running your regular LANDIS-II installation with `landis-ii-8` in a terminal. To launch the dockerized version, you can use the LANDIS-II Docker Launcher that will be installed with this installer (see more information below), or use a `docker run` command (see [Tool-Docker-Apptainer](https://github.com/LANDIS-II-Foundation/Tool-Docker-Apptainer) for specific instructions).


---

## How it works

| Piece | What it does |
|---|---|
| **Installer** (`LANDIS-II-Docker-Installer.exe`) | WSL2 setup → Docker check → clones & builds LANDIS-II images → installs the launcher. Self-elevates as admin. |
| **Launcher** (`LANDIS-II-Docker-Launcher.exe`) | Lets you pick your **simulation folder** + **scenario file** in Explorer, then runs LANDIS-II inside Docker and streams the output. |
| **Uninstaller** (`Uninstall-LANDIS-II-Launcher.exe`) | Cleanly removes the launcher and its Start Menu entries. |
| **`install-landis-ii.ps1`** | The PowerShell source of the installer — everything you see above in script form. |

```
┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
│   WSL2 + Docker    │──▶│  Build LANDIS-II   │──▶│  Launcher runs     │
│  Desktop check     │   │  images (pinned)   │   │  simulations       │
└────────────────────┘   └────────────────────┘   └────────────────────┘
        installs 6 steps                 builds              runs
```


---

## Requirements

- **Windows 10 or 11** (64-bit)
- **Administrator** rights (the installer self-elevates)
- ~**10 GB** of free disk space
- A working internet connection
- **4–8 GB** of free RAM if you build an Apptainer image (optional)

Docker Desktop and Git are **not** required beforehand — the installer checks for them, and if Git is missing it downloads a portable copy automatically. (It will still guide you to install Docker Desktop.)

---

## Installation

### Option A — The quick way (recommended)

1. Grab the latest **`LANDIS-II-Docker-Installer.exe`** from the [Releases](https://github.com/Klemet/LANDIS-II-Docker-Installer/releases) page.
2. Double-click it. It asks for admin permission, then walks you through **6 steps**.
3. **Done.** A "LANDIS-II Docker Launcher" shortcut appears in your Start Menu.

> A reboot may be requested once while WSL2 is being enabled — just re-run the installer afterwards and it resumes right where it left off.

### Option B — From source

```powershell
# From an elevated PowerShell (right-click → "Run as administrator")
powershell -ExecutionPolicy Bypass -File .\install-landis-ii.ps1
```

### What the 6 install steps do

1. **WSL2** — enable the required Windows features, reboot if needed, install WSL.
2. **Docker Desktop** — verify it's installed and running (up to 5 guided retries).
3. **Git** — use the system copy, or download a portable one automatically.
4. **Base image** — build `landis-ii-v8-uclv2-release:ubuntu-26.04` from a pinned commit.
5. **DIVERSE image** — build `landis-ii-v8-uclv2-diverse:latest` (the actual simulation image).
6. **Launcher** — install the program + Start Menu shortcuts for all users.

Build logs are saved to `%LOCALAPPDATA%\LANDIS-II-Docker\logs\` so you can always see exactly what happened.

---

## Running a simulation

1. Make sure **Docker Desktop** is running.
2. Open **"LANDIS-II Docker Launcher"** from the Windows Start Menu (where you find your programs).
3. Pick the **simulation folder** (Explorer folder dialog).
4. Pick your **scenario `.txt`** file.
5. Sit back — LANDIS-II runs inside Docker and the output streams to your console.

Your scenario file can live anywhere inside the simulation folder (even in sub-folders); the launcher figures out the relative path automatically.

---

## Optional: create an Apptainer (`.sif`) image

For High-Performance Computing (HPC) clusters, you can convert your Docker image to Apptainer:

- In the installer's main menu, choose **(OPTIONAL) CREATE APPTAINER**.
- Pick an output folder.
- The `.sif` file (usable on cluster schedulers like SLURM) is written there.

> ⚠️ This step needs **4–8 GB of free RAM** — close other apps first, or the build will crash.

---

## Uninstalling

Use **"Uninstall LANDIS-II Docker Launcher"** from the Start Menu to remove the launcher.

To remove everything — WSL2, Docker Desktop, and the launcher — run the installer's main menu → **UNINSTALL**, and choose:

- `[1] Remove ALL (WSL2 + Docker Desktop + Launcher)`
- `[2] Remove WSL2 only`
- `[3] Remove Docker Desktop only`
- `[4] Remove Launcher only`

Each destructive step asks for confirmation before doing anything.

---

## What gets installed & where

```
%LOCALAPPDATA%\LANDIS-II-Docker\
├── logs\                         # Docker build logs
└── repos\                        # temp cloned repos (cleaned up)

C:\Program Files\LANDIS-II Docker Launcher\
├── LANDIS-II-Docker-Launcher.exe
└── Uninstall-LANDIS-II-Launcher.exe

%ProgramData%\Microsoft\Windows\Start Menu\Programs\LANDIS-II Docker Launcher\
└── LANDIS-II Docker Launcher.lnk
```

**Docker images** (built once, reused forever):

```
landis-ii-v8-uclv2-release:ubuntu-26.04   # base LANDIS-II v8
landis-ii-v8-uclv2-diverse:latest         # simulation image (DIVERSE extensions)
```

---

## Why pinned commits?

Instead of cloning "latest" (which can change under you), the installer checks out **specific, reproducible commits**:

- `Tool-Docker-Apptainer` → commit `4a91482`
- `Docker-LANDIS-II-v8-DIVERSE` → commit `08727e4`

So every machine gets *exactly* the same software — critical for reproducible science.

---

## Troubleshooting

The installer does a lot of this for you, categorizing build failures and suggesting fixes. Common issues:

| Symptom | Likely cause / fix |
|---|---|
| `Could not resolve github.com` at startup | Corporate firewall / VPN / proxy blocking GitHub or Docker Hub. |
| "ExecutionPolicy is Restricted" | A policy on your machine; the installer tries to bypass it for its own process and tells you if it can't. |
| Docker build fails | The installer parses the log into categories (network/SSL, connection, .NET compile, Dockerfile step) and prints the exact log path. |
| Launcher says "Docker is not running" | Start Docker Desktop and wait for it to be ready, then retry. |
| Image not found in launcher | Run the installer first to build the images. |

**If a build fails**, please [open an issue](https://github.com/Klemet/LANDIS-II-Docker-Installer/issues) and attach the log file from `%LOCALAPPDATA%\LANDIS-II-Docker\logs\` — it makes diagnosis much faster.

---

## Building the executables from source

The `.exe` files are built from the `.ps1` scripts using the .NET Framework `csc.exe` that ships with Windows (no extra tooling). Run:

```powershell
.\build-exes.ps1
```

Outputs land in `dist\`. Drop your own icons in `build\icons\` first if you'd like custom branding.

---

## Project structure

```
├── install-landis-ii.ps1            # The installer (source of truth)
├── LANDIS-II-Docker-Launcher.ps1    # Launcher script
├── Uninstall-LANDIS-II-Launcher.ps1 # Uninstaller script
├── build-exes.ps1                   # Builds the .exe wrappers
├── build\                           # C# launcher source, manifests, icons
├── dist\                            # Compiled executables + installer zip
└── PLAN.md                          # Original design & implementation plan
```

---

<div align="center">

**Questions or ideas?** [Open an issue](https://github.com/Klemet/LANDIS-II-Docker-Installer/issues) — contributions welcome.

</div>
