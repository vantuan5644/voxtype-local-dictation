using System;
using System.Diagnostics;
using System.IO;

internal static class ServerLauncher
{
    public static int Main()
    {
        var script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "windows", "voxtype-local.ps1");
        if (!File.Exists(script)) return 0;
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory,
                @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
                "-WindowStyle Hidden -File \"" +
                script.Replace("\"", "\"\"") + "\" cleanup-server",
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        using (var child = Process.Start(start))
        {
            if (child == null) return 0;
            child.WaitForExit();
            return child.ExitCode;
        }
    }
}
