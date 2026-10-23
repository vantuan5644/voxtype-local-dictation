using System;
using System.IO;

// Offline checks for packaging/CleanupBackend.cs, the launchers' reading of the cleanup
// choice. test-windows.ps1 checks the same rules in voxtype-cleanup-backend.ps1.
internal static class CleanupBackendTests
{
    private static int failures;

    private static int Main()
    {
        Environment.SetEnvironmentVariable("VOXTYPE_CLEANUP_BACKEND", null);
        Expect("single link", "pi", CleanupBackend.Normalize("pi"));
        Expect("case and spaces", "pi,local", CleanupBackend.Normalize(" Pi , LOCAL "));
        Expect("off alone", "off", CleanupBackend.Normalize("off"));
        Expect("long chain", "claude,codex,openai,local",
            CleanupBackend.Normalize("claude,codex,openai,local"));
        foreach (var invalid in new[] { null, "", "  ", "local,pi", "off,pi", "pi,off",
                "pi,,local", "pi,pi", "bogus", "pi;local" })
            Expect("rejects <" + invalid + ">", null, CleanupBackend.Normalize(invalid));

        var root = Path.Combine(Path.GetTempPath(),
            "voxtype-cleanup-backend-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "models"));
        try
        {
            var choice = Path.Combine(root, CleanupBackend.FileName);
            var defaultModel = Path.Combine(root, "models", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf");
            Expect("absent file means local", "local", CleanupBackend.Effective(root));
            Expect("absent file is not a recorded choice", null, CleanupBackend.ReadRecorded(root));
            ExpectTrue("no server without the model", !CleanupBackend.WantsLocalServer(root));
            File.WriteAllText(defaultModel, "model");
            ExpectTrue("server for local and the default model", CleanupBackend.WantsLocalServer(root));

            File.WriteAllText(choice, "pi");
            Expect("recorded choice", "pi", CleanupBackend.ReadRecorded(root));
            ExpectTrue("no server for pi", !CleanupBackend.WantsLocalServer(root));

            File.WriteAllText(choice, "pi,local\r\n");
            var recorded = Path.Combine(root, "cleanup-model.path");
            var custom = Path.Combine(root, "custom.gguf");
            File.WriteAllText(recorded, custom);
            ExpectTrue("no server when the recorded model is missing",
                !CleanupBackend.WantsLocalServer(root));
            File.WriteAllText(custom, "model");
            ExpectTrue("server for pi,local and the recorded model",
                CleanupBackend.WantsLocalServer(root));

            File.WriteAllText(choice, "local,pi");
            Expect("invalid file has no chain", null, CleanupBackend.Effective(root));
            ExpectTrue("no server for an invalid file", !CleanupBackend.WantsLocalServer(root));

            File.WriteAllText(choice, "local");
            Environment.SetEnvironmentVariable("VOXTYPE_CLEANUP_BACKEND", "pi");
            Expect("environment wins over the file", "pi", CleanupBackend.Effective(root));
            ExpectTrue("no server when the environment says pi",
                !CleanupBackend.WantsLocalServer(root));
            Environment.SetEnvironmentVariable("VOXTYPE_CLEANUP_BACKEND", null);
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { }
        }
        Console.WriteLine(failures == 0 ? "Cleanup backend tests passed." :
            failures + " cleanup backend test(s) failed.");
        return failures == 0 ? 0 : 1;
    }

    private static void Expect(string name, string expected, string actual)
    {
        if (expected == actual) return;
        failures++;
        Console.WriteLine("FAIL " + name + ": expected <" + expected + ">, got <" + actual + ">");
    }

    private static void ExpectTrue(string name, bool value)
    {
        if (value) return;
        failures++;
        Console.WriteLine("FAIL " + name);
    }
}
