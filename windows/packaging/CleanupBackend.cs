using System;
using System.Collections.Generic;
using System.IO;

// The cleanup choice as the launchers read it. windows\voxtype-cleanup-backend.ps1 holds the
// same rules for the scripts: an ordered, comma-separated chain of opencode, anthropic, groq, pi,
// local, openai, claude and codex, or the single value off; local only as the last link. Precedence is
// VOXTYPE_CLEANUP_BACKEND, then <LocalAppData>\VoxType\cleanup-backend (written by
// voxtype-setup.ps1 -CleanupBackend), then local.
internal static class CleanupBackend
{
    internal const string FileName = "cleanup-backend";
    internal const string DefaultChain = "local";
    private static readonly string[] Names = { "opencode", "anthropic", "groq", "pi", "local", "openai", "claude", "codex" };

    // The canonical chain ("opencode,local"), or null when the value breaks a rule.
    internal static string Normalize(string value)
    {
        if (value == null || value.Trim().Length == 0) return null;
        var links = new List<string>();
        foreach (var part in value.Split(','))
        {
            var link = part.Trim().ToLowerInvariant();
            if (link.Length == 0 || links.Contains(link)) return null;
            if (link != "off" && Array.IndexOf(Names, link) < 0) return null;
            links.Add(link);
        }
        if (links.Contains("off") && links.Count > 1) return null;
        var local = links.IndexOf("local");
        if (local >= 0 && local != links.Count - 1) return null;
        return String.Join(",", links.ToArray());
    }

    // The recorded file's chain, or null when it is absent or invalid.
    internal static string ReadRecorded(string dataDirectory)
    {
        var path = Path.Combine(dataDirectory, FileName);
        try { return File.Exists(path) ? Normalize(File.ReadAllText(path)) : null; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    // The chain cleanup will use, or null when the configured value is invalid (cleanup then
    // passes text through unchanged).
    internal static string Effective(string dataDirectory)
    {
        var environment = Environment.GetEnvironmentVariable("VOXTYPE_CLEANUP_BACKEND");
        if (!String.IsNullOrEmpty(environment)) return Normalize(environment);
        var path = Path.Combine(dataDirectory, FileName);
        if (!File.Exists(path)) return DefaultChain;
        return ReadRecorded(dataDirectory);
    }

    // Whether voxtype-cleanup.ps1 finds an OpenCode Go key: VOXTYPE_CLEANUP_OPENCODE_KEY, or
    // the one pi keeps in its auth.json, which is read in place and never copied.
    internal static bool HasOpenCodeKey()
    {
        if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("VOXTYPE_CLEANUP_OPENCODE_KEY")))
            return true;
        var agent = Environment.GetEnvironmentVariable("PI_CODING_AGENT_DIR");
        if (String.IsNullOrEmpty(agent))
            agent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".pi", "agent");
        var auth = Path.Combine(agent, "auth.json");
        try { return File.Exists(auth) && File.ReadAllText(auth).Contains("\"opencode-go\""); }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    internal static bool ContainsLocal(string chain)
    {
        return chain != null && Array.IndexOf(chain.Split(','), "local") >= 0;
    }

    // The resident llama.cpp server is worth starting only when cleanup can use it: the
    // chain contains local and the model recorded in cleanup-model.path exists. Without a
    // recorded path, the default location voxtype-server.ps1 also falls back to is checked.
    internal static bool WantsLocalServer(string dataDirectory)
    {
        if (!ContainsLocal(Effective(dataDirectory))) return false;
        string model;
        try
        {
            var recorded = Path.Combine(dataDirectory, "cleanup-model.path");
            model = File.Exists(recorded) ? File.ReadAllText(recorded).Trim() : "";
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        if (model.Length == 0)
            model = Path.Combine(dataDirectory, "models", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf");
        return File.Exists(model);
    }
}
