using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Runtime.InteropServices;

internal sealed class BootstrapForm : Form
{
    private const string ExpectedVersion = "@@VERSION@@";
    private const string ExpectedPublisher = "@@PUBLISHER@@";
    private const string OnlineManifestUrl = "@@MANIFEST_URL@@";

    private readonly string offlineDirectory;
    private readonly bool installOnly;
    private readonly string logPath;
    private readonly Label status = new Label();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly Button action = new Button();
    private bool finished;
    public int ResultCode { get; private set; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct OsVersionInfo
    {
        public uint Size;
        public uint Major;
        public uint Minor;
        public uint Build;
        public uint Platform;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string ServicePack;
        public ushort ServicePackMajor;
        public ushort ServicePackMinor;
        public ushort SuiteMask;
        public byte ProductType;
        public byte Reserved;
    }

    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    private static extern int RtlGetVersion(ref OsVersionInfo version);

    public BootstrapForm(string offlineDirectory, bool installOnly, string logPath)
    {
        this.offlineDirectory = offlineDirectory;
        this.installOnly = installOnly;
        this.logPath = logPath;
        Text = "Install VoxType";
        ClientSize = new Size(560, 245);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9F);

        var title = new Label();
        title.Text = "VoxType local dictation";
        title.Font = new Font("Segoe UI Semibold", 18F);
        title.SetBounds(24, 22, 510, 38);
        Controls.Add(title);
        var detail = new Label();
        detail.Text = "Installs for your Windows account, then helps you choose a microphone, " +
            "push-to-talk key, and local models.";
        detail.SetBounds(27, 70, 505, 42);
        Controls.Add(detail);
        progress.SetBounds(27, 125, 505, 19);
        progress.Style = ProgressBarStyle.Marquee;
        progress.MarqueeAnimationSpeed = 25;
        Controls.Add(progress);
        status.Text = "Ready to install version " + ExpectedVersion + ".";
        status.SetBounds(27, 154, 505, 35);
        Controls.Add(status);
        action.Text = "Install";
        action.SetBounds(407, 195, 125, 32);
        action.Click += ActionClicked;
        Controls.Add(action);
        ResultCode = 1;
    }

    private async void ActionClicked(object sender, EventArgs args)
    {
        if (finished) { Close(); return; }
        action.Enabled = false;
        try
        {
            await Task.Run((Action)Install);
            ResultCode = 0;
            finished = true;
            SetStatus("VoxType is installed.");
            SetAction("Close", true);
        }
        catch (InstallException exception)
        {
            ResultCode = exception.Code;
            AppendLog(exception.ToString());
            SetStatus(exception.Message);
            SetAction("Close", true);
        }
        catch (Exception exception)
        {
            ResultCode = 30;
            AppendLog(exception.ToString());
            SetStatus("Installation failed: " + exception.Message);
            SetAction("Close", true);
        }
    }

    private void Install()
    {
        EnsureSupportedWindows();
        var cache = Path.Combine(Path.GetTempPath(), "VoxTypeSetup", ExpectedVersion);
        Directory.CreateDirectory(cache);
        var localManifest = FindLocalManifest();
        var manifestPath = localManifest ?? Path.Combine(cache, "release-manifest.json");
        if (localManifest == null)
        {
            SetStatus("Downloading the signed release description...");
            Download(OnlineManifestUrl, manifestPath);
        }
        var manifest = ReadManifest(manifestPath);
        ValidateManifest(manifest);
        var sourceDirectory = Path.GetDirectoryName(manifestPath);
        var localPackage = Path.Combine(sourceDirectory, manifest.MsixFileName);
        var packageWasAdjacent = localManifest != null && File.Exists(localPackage);
        var packagePath = packageWasAdjacent ? localPackage :
            Path.Combine(cache, manifest.MsixFileName);
        if (!File.Exists(packagePath))
        {
            SetStatus("Downloading VoxType...");
            Download(manifest.MsixUrl, packagePath);
        }
        SetStatus("Verifying the package...");
        try { VerifyHash(packagePath, manifest.MsixSha256); }
        catch
        {
            if (!packageWasAdjacent)
                File.Delete(packagePath);
            throw;
        }
        VerifySignature(packagePath);
        SetStatus("Installing VoxType for this Windows account...");
        InstallPackage(packagePath);
        if (!installOnly)
        {
            SetStatus("Opening first-run setup...");
            Process.Start(new ProcessStartInfo("voxtype-configure:") { UseShellExecute = true });
        }
        AppendLog("Installed " + packagePath);
    }

    private string FindLocalManifest()
    {
        if (!String.IsNullOrWhiteSpace(offlineDirectory))
        {
            var selected = Path.Combine(Path.GetFullPath(offlineDirectory), "release-manifest.json");
            if (!File.Exists(selected))
                throw new InstallException(2, "The offline folder has no release-manifest.json.");
            return selected;
        }
        var adjacent = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "release-manifest.json");
        return File.Exists(adjacent) ? adjacent : null;
    }

    private static ReleaseManifest ReadManifest(string path)
    {
        try
        {
            var serializer = new JavaScriptSerializer();
            var root = serializer.DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>;
            if (root == null) throw new InvalidDataException();
            var msix = root["msix"] as Dictionary<string, object>;
            if (msix == null) throw new InvalidDataException();
            return new ReleaseManifest
            {
                Version = Convert.ToString(root["version"]),
                Publisher = Convert.ToString(root["publisher"]),
                Identity = Convert.ToString(root["packageIdentity"]),
                MsixFileName = Convert.ToString(msix["fileName"]),
                MsixUrl = Convert.ToString(msix["url"]),
                MsixSha256 = Convert.ToString(msix["sha256"])
            };
        }
        catch (Exception exception)
        {
            throw new InstallException(20, "The release description is invalid.", exception);
        }
    }

    private static void ValidateManifest(ReleaseManifest manifest)
    {
        if (manifest.Version != ExpectedVersion || manifest.Publisher != ExpectedPublisher ||
            manifest.Identity != "VoxType.Windows")
            throw new InstallException(20, "The release description does not match this installer.");
        if (String.IsNullOrWhiteSpace(manifest.MsixFileName) ||
            Path.GetFileName(manifest.MsixFileName) != manifest.MsixFileName)
            throw new InstallException(20, "The package filename is invalid.");
        Uri uri;
        if (!Uri.TryCreate(manifest.MsixUrl, UriKind.Absolute, out uri) || uri.Scheme != "https")
            throw new InstallException(20, "The package URL must use HTTPS.");
        if (manifest.MsixSha256 == null || manifest.MsixSha256.Length != 64)
            throw new InstallException(20, "The package digest is invalid.");
    }

    private static void EnsureSupportedWindows()
    {
        var version = new OsVersionInfo();
        version.Size = (uint)Marshal.SizeOf(typeof(OsVersionInfo));
        if (Environment.OSVersion.Platform != PlatformID.Win32NT ||
            !Environment.Is64BitOperatingSystem || RtlGetVersion(ref version) != 0 ||
            version.Build < 22621)
            throw new InstallException(10, "VoxType requires 64-bit Windows 11 build 22621 or newer.");
    }

    private static void Download(string url, string destination)
    {
        Uri uri;
        if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != "https")
            throw new InstallException(20, "Download URL must use HTTPS.");
        var partial = destination + ".partial";
        var existing = File.Exists(partial) ? new FileInfo(partial).Length : 0L;
        var request = (HttpWebRequest)WebRequest.Create(uri);
        request.UserAgent = "VoxType-Windows-Setup/" + ExpectedVersion;
        if (existing > 0) request.AddRange(existing);
        using (var response = (HttpWebResponse)request.GetResponse())
        {
            var append = existing > 0 && response.StatusCode == HttpStatusCode.PartialContent;
            using (var input = response.GetResponseStream())
            using (var output = new FileStream(partial, append ? FileMode.Append : FileMode.Create,
                FileAccess.Write, FileShare.None))
                input.CopyTo(output);
        }
        if (File.Exists(destination)) File.Delete(destination);
        File.Move(partial, destination);
    }

    private static void VerifyHash(string path, string expected)
    {
        string actual;
        using (var stream = File.OpenRead(path))
        using (var sha = SHA256.Create())
            actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
        if (!String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
            throw new InstallException(20, "The downloaded package failed its SHA-256 check.");
    }

    private static void VerifySignature(string path)
    {
        var quotedPath = path.Replace("'", "''");
        var quotedPublisher = ExpectedPublisher.Replace("'", "''");
        var command = "$s=Get-AuthenticodeSignature -LiteralPath '" + quotedPath + "';" +
            "if($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -cne '" +
            quotedPublisher + "'){exit 1}";
        var result = RunPowerShell(command, 60000);
        if (result != 0)
            throw new InstallException(20, "The package signature or publisher is invalid.");
    }

    private static void InstallPackage(string path)
    {
        var command = "Add-AppxPackage -LiteralPath '" + path.Replace("'", "''") +
            "' -ForceApplicationShutdown";
        var result = RunPowerShell(command, 300000);
        if (result != 0) throw new InstallException(30, "Windows could not install the MSIX package.");
    }

    private static int RunPowerShell(string command, int timeout)
    {
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory,
                @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using (var process = Process.Start(start))
        {
            if (process == null) return 1;
            if (!process.WaitForExit(timeout))
            {
                try { process.Kill(); } catch { }
                return 1;
            }
            return process.ExitCode;
        }
    }

    private void AppendLog(string message)
    {
        if (String.IsNullOrWhiteSpace(logPath)) return;
        try
        {
            var parent = Path.GetDirectoryName(Path.GetFullPath(logPath));
            if (!Directory.Exists(parent)) Directory.CreateDirectory(parent);
            File.AppendAllText(logPath, DateTimeOffset.Now.ToString("o") + " " + message +
                Environment.NewLine);
        }
        catch { }
    }

    private void SetStatus(string value)
    {
        if (status.InvokeRequired) status.BeginInvoke((Action)delegate { status.Text = value; });
        else status.Text = value;
    }

    private void SetAction(string text, bool enabled)
    {
        if (action.InvokeRequired)
            action.BeginInvoke((Action)delegate { action.Text = text; action.Enabled = enabled; });
        else { action.Text = text; action.Enabled = enabled; }
    }

    private sealed class ReleaseManifest
    {
        public string Version;
        public string Publisher;
        public string Identity;
        public string MsixFileName;
        public string MsixUrl;
        public string MsixSha256;
    }
}

internal sealed class InstallException : Exception
{
    public readonly int Code;
    public InstallException(int code, string message) : base(message) { Code = code; }
    public InstallException(int code, string message, Exception inner) : base(message, inner)
    { Code = code; }
}

internal static class BootstrapInstaller
{
    [STAThread]
    public static int Main(string[] args)
    {
        string offlineDirectory = null;
        string logPath = null;
        var installOnly = false;
        for (var index = 0; index < args.Length; index++)
        {
            if (args[index] == "--offline-dir" && index + 1 < args.Length)
                offlineDirectory = args[++index];
            else if (args[index] == "--log" && index + 1 < args.Length)
                logPath = args[++index];
            else if (args[index] == "--install-only") installOnly = true;
            else
            {
                MessageBox.Show("Usage: VoxTypeSetup.exe [--offline-dir PATH] " +
                    "[--install-only] [--log PATH]", "VoxType setup");
                return 2;
            }
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        var form = new BootstrapForm(offlineDirectory, installOnly, logPath);
        Application.Run(form);
        return form.ResultCode;
    }
}
