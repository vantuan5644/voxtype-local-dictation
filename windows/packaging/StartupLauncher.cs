using System;
using System.Diagnostics;
using System.IO;

internal static class StartupLauncher
{
    public static int Main()
    {
        var data = Path.Combine(Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData), "VoxType");
        if (!File.Exists(Path.Combine(data, "startup.enabled"))) return 0;
        var root = AppDomain.CurrentDomain.BaseDirectory;
        Start(Path.Combine(root, "voxtype.exe"));
        Start(Path.Combine(root, "voxtype-cleanup-server.exe"));
        return 0;
    }

    private static void Start(string executable)
    {
        if (!File.Exists(executable)) return;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
        }
        catch { }
    }
}
