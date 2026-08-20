using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

internal static class LandisLauncher
{
    // Must match the resource name passed to csc via /resource:<file>,LandisScript.ps1
    private const string ResName = "LandisScript.ps1";

    private static int Main(string[] args)
    {
        string tempFile = null;
        try
        {
            // Extract the embedded .ps1 to a temp file (preserves original bytes/encoding).
            using (Stream rs = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResName))
            {
                if (rs == null)
                {
                    Console.Error.WriteLine("Embedded script resource not found: " + ResName);
                    return 2;
                }
                tempFile = Path.Combine(Path.GetTempPath(), "Landis_" + Guid.NewGuid().ToString("N") + ".ps1");
                using (FileStream fs = new FileStream(tempFile, FileMode.Create, FileAccess.Write))
                {
                    rs.CopyTo(fs);
                }
            }

            // Launch the script in this same console so all interactive
            // Write-Host / Read-Host output behaves exactly as the original .ps1.
            string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + tempFile + "\"",
                UseShellExecute = false,
                WorkingDirectory = exeDir
            };

            // Tell the script where this .exe lives so it can locate sibling files
            // (e.g. the installer finding the launcher/uninstaller .exe to install).
            psi.EnvironmentVariables["LANDIS_LAUNCHER_DIR"] = exeDir;

            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Launcher error: " + ex.Message);
            return 2;
        }
        finally
        {
            if (tempFile != null)
            {
                try { File.Delete(tempFile); } catch { /* best effort */ }
            }
        }
    }
}
