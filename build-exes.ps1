# Builds the LANDIS-II launcher/installer/uninstaller .exe files.
#
# Approach: each .ps1 is embedded as a resource inside a small C# launcher exe
# (compiled with the .NET Framework csc.exe that ships with Windows). At run
# time the launcher extracts the .ps1 to a temp file and runs it via
# `powershell.exe -File` in the SAME console, so all interactive Write-Host /
# Read-Host behavior works exactly like the original script.
#
# The installer and uninstaller exes use requireAdministrator manifests so they
# self-elevate (they need to write to Program Files / ProgramData).
# ps2exe was dropped because it breaks Read-Host in these scripts.
#
# Icons: each exe gets an icon from build\icons\<name>.ico. If the .ico does not
# exist yet, a simple placeholder is generated. Drop your own .ico files in
# build\icons\ and re-run this script to embed them (placeholders are never
# overwritten).
#   build\icons\installer.ico   -> LANDIS-II-Docker-Installer.exe
#   build\icons\launcher.ico    -> LANDIS-II-Docker-Launcher.exe
#   build\icons\uninstaller.ico -> Uninstall-LANDIS-II-Launcher.exe

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$csc  = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
}

$srcDir    = Join-Path $root 'build'
$iconsDir  = Join-Path $srcDir 'icons'
$dist      = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
New-Item -ItemType Directory -Force -Path $iconsDir | Out-Null

$launcherCs = Join-Path $srcDir 'Launcher.cs'

# ---- Icon generation ---------------------------------------------------------

function New-PlaceholderIcon {
    param(
        [string]$Path,
        [int]$Size = 32,
        [int[]]$Bg = @(23, 42, 64),
        [int[]]$Fg = @(0, 200, 210),
        [string]$Glyph = 'L'
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    function Test-Glyph {
        param([int]$x, [int]$y, [string]$g)
        switch ($g) {
            'I' { return ($x -ge 14 -and $x -le 17 -and $y -ge 4 -and $y -le 27) }
            'L' {
                $v = ($x -ge 6 -and $x -le 9 -and $y -ge 4 -and $y -le 27)
                $h = ($y -ge 24 -and $y -le 27 -and $x -ge 6 -and $x -le 29)
                return ($v -or $h)
            }
            'U' {
                $l = ($x -ge 6 -and $x -le 9 -and $y -ge 4 -and $y -le 27)
                $r = ($x -ge 22 -and $x -le 25 -and $y -ge 4 -and $y -le 27)
                $b = ($y -ge 24 -and $y -le 27 -and $x -ge 6 -and $x -le 25)
                return ($l -or $r -or $b)
            }
            default { return $false }
        }
    }

    $pixelRows = New-Object System.Collections.Generic.List[byte]
    for ($row = $Size - 1; $row -ge 0; $row--) {
        for ($col = 0; $col -lt $Size; $col++) {
            if (Test-Glyph -x $col -y $row -g $Glyph) {
                $pixelRows.Add($Fg[2]); $pixelRows.Add($Fg[1]); $pixelRows.Add($Fg[0]); $pixelRows.Add([byte]255)
            } else {
                $pixelRows.Add($Bg[2]); $pixelRows.Add($Bg[1]); $pixelRows.Add($Bg[0]); $pixelRows.Add([byte]255)
            }
        }
    }

    $maskBytesPerRow = [int]([math]::Ceiling($Size / 8.0) * 4)
    $andMask = New-Object byte[] ($maskBytesPerRow * $Size)

    $bih = New-Object System.Collections.Generic.List[byte]
    $bih.AddRange([BitConverter]::GetBytes([int]40))
    $bih.AddRange([BitConverter]::GetBytes([int]$Size))
    $bih.AddRange([BitConverter]::GetBytes([int]($Size * 2)))
    $bih.AddRange([BitConverter]::GetBytes([int16]1))
    $bih.AddRange([BitConverter]::GetBytes([int16]32))
    $bih.AddRange([BitConverter]::GetBytes([int]0))
    $bih.AddRange([BitConverter]::GetBytes([int]0))
    $bih.AddRange([BitConverter]::GetBytes([int]0))
    $bih.AddRange([BitConverter]::GetBytes([int]0))
    $bih.AddRange([BitConverter]::GetBytes([int]0))
    $bih.AddRange([BitConverter]::GetBytes([int]0))

    $imageBytes = New-Object System.Collections.Generic.List[byte]
    $imageBytes.AddRange($bih)
    $imageBytes.AddRange($pixelRows)
    $imageBytes.AddRange($andMask)

    $bytesInRes = $imageBytes.Count

    $icon = New-Object System.Collections.Generic.List[byte]
    $icon.AddRange([byte[]](0, 0))                 # reserved
    $icon.AddRange([byte[]](1, 0))                 # type = icon
    $icon.AddRange([byte[]](1, 0))                 # count = 1
    $icon.Add([byte]$Size); $icon.Add([byte]$Size) # width, height
    $icon.Add([byte]0); $icon.Add([byte]0)         # palette, reserved
    $icon.AddRange([BitConverter]::GetBytes([int16]1))    # planes
    $icon.AddRange([BitConverter]::GetBytes([int16]32))   # bpp
    $icon.AddRange([BitConverter]::GetBytes([uint32]$bytesInRes))
    $icon.AddRange([BitConverter]::GetBytes([uint32]22))  # offset

    $icon.AddRange($imageBytes)

    [System.IO.File]::WriteAllBytes($Path, $icon.ToArray())
}

# ---- Build specs -------------------------------------------------------------

$specs = @(
    @{
        Script   = 'install-landis-ii.ps1'
        Out      = 'LANDIS-II-Docker-Installer.exe'
        Manifest = 'LandisInstaller.manifest'
        Icon     = 'installer.ico'
        Glyph    = 'I'
        Fg       = @(90, 220, 90)
    },
    @{
        Script   = 'LANDIS-II-Docker-Launcher.ps1'
        Out      = 'LANDIS-II-Docker-Launcher.exe'
        Manifest = 'LandisApp.manifest'
        Icon     = 'launcher.ico'
        Glyph    = 'L'
        Fg       = @(0, 200, 210)
    },
    @{
        Script   = 'Uninstall-LANDIS-II-Launcher.ps1'
        Out      = 'Uninstall-LANDIS-II-Launcher.exe'
        Manifest = 'LandisUninstaller.manifest'
        Icon     = 'uninstaller.ico'
        Glyph    = 'U'
        Fg       = @(230, 90, 90)
    }
)

foreach ($spec in $specs) {
    $scriptPath   = Join-Path $root $spec.Script
    $outPath      = Join-Path $dist $spec.Out
    $manifestPath = Join-Path $srcDir $spec.Manifest
    $iconPath     = Join-Path $iconsDir $spec.Icon

    # Create a placeholder icon only if the user hasn't provided one.
    if (-not (Test-Path -LiteralPath $iconPath)) {
        New-PlaceholderIcon -Path $iconPath -Glyph $spec.Glyph -Fg $spec.Fg
        Write-Host "  (generated placeholder icon: $iconPath)"
    }

    $args = @(
        '/nologo',
        '/target:exe',
        '/optimize+',
        "/out:$outPath",
        "/win32manifest:$manifestPath"
    )
    if (Test-Path -LiteralPath $iconPath) {
        $args += "/win32icon:$iconPath"
    }
    $args += @(
        "/resource:$scriptPath,LandisScript.ps1",
        $launcherCs
    )

    Write-Host "Building $($spec.Out) ..."
    & $csc $args
    if ($LASTEXITCODE -ne 0) {
        throw "csc failed while building $($spec.Out)"
    }
    Write-Host "  -> $outPath"
}

Write-Host ""
Write-Host "All executables built into: $dist"
Write-Host "Custom icons go here:       $iconsDir"

pause