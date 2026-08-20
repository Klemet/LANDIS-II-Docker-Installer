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