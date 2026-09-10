using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class Launcher
{
    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            return value;
        var result = new StringBuilder("\"");
        var slashes = 0;
        foreach (var ch in value)
        {
            if (ch == '\\') { slashes++; continue; }
            if (ch == '"')
            {
                result.Append('\\', slashes * 2 + 1).Append('"');
            }
            else
            {
                result.Append('\\', slashes).Append(ch);
            }
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    public static int Main(string[] args)
    {
        var script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "windows", "voxtype-local.ps1");
        if (!File.Exists(script))
        {
            Console.Error.WriteLine("voxtype-local: packaged script is missing: " + script);
            return 1;
        }
        var allArgs = new string[5];
        allArgs[0] = "-NoLogo";
        allArgs[1] = "-NoProfile";
        allArgs[2] = "-NonInteractive";
        allArgs[3] = "-ExecutionPolicy";
        allArgs[4] = "Bypass";
        var command = new StringBuilder();
        foreach (var fixedArg in allArgs)
        {
            if (fixedArg == null) break;
            if (command.Length > 0) command.Append(' ');
            command.Append(Quote(fixedArg));
        }
        command.Append(" -File ").Append(Quote(script));
        foreach (var arg in args) command.Append(' ').Append(Quote(arg));

        var forwardsInput = args.Length > 0 &&
            string.Equals(args[0], "cleanup", StringComparison.OrdinalIgnoreCase);
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory,
                @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = command.ToString(),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = forwardsInput,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        using (var child = Process.Start(start))
        {
            if (child == null) return 1;
            var stdout = child.StandardOutput.ReadToEndAsync();
            var stderr = child.StandardError.ReadToEndAsync();
            if (forwardsInput)
            {
                Console.OpenStandardInput().CopyTo(child.StandardInput.BaseStream);
                child.StandardInput.Close();
            }
            child.WaitForExit();
            Console.Out.Write(stdout.GetAwaiter().GetResult());
            Console.Error.Write(stderr.GetAwaiter().GetResult());
            return child.ExitCode;
        }
    }
}
