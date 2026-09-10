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

internal sealed class ConfigureForm : Form
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct WaveInCaps
    {
        public ushort ManufacturerId;
        public ushort ProductId;
        public uint DriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string ProductName;
        public uint Formats;
        public ushort Channels;
        public ushort Reserved;
    }

    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    private static extern uint waveInGetNumDevs();

    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    private static extern uint waveInGetDevCaps(UIntPtr deviceId, out WaveInCaps caps, uint size);

    private readonly string baseDirectory;
    private readonly string dataDirectory;
    private readonly ComboBox microphones = new ComboBox();
    private readonly TextBox hotkey = new TextBox();
    private readonly RadioButton onlineModels = new RadioButton();
    private readonly RadioButton offlineModels = new RadioButton();
    private readonly TextBox offlineDirectory = new TextBox();
    private readonly Button browse = new Button();
    private readonly CheckBox startup = new CheckBox();
    private readonly Label hardware = new Label();
    private readonly Label status = new Label();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly Button install = new Button();
    private readonly Button soundSettings = new Button();

    public ConfigureForm()
    {
        baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        dataDirectory = Path.Combine(Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData), "VoxType");
        Text = "Set up VoxType";
        ClientSize = new Size(700, 590);
        MinimumSize = new Size(716, 629);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9F);

        var title = NewLabel("VoxType local dictation", 24, 18, 640, 35);
        title.Font = new Font("Segoe UI Semibold", 20F);
        Controls.Add(title);
        Controls.Add(NewLabel(
            "Speech and cleanup stay on this PC. Setup needs about 4 GB of free disk space.",
            27, 58, 640, 35));

        var hardwareTitle = NewLabel("Hardware", 27, 102, 200, 24);
        hardwareTitle.Font = new Font("Segoe UI Semibold", 11F);
        Controls.Add(hardwareTitle);
        hardware.SetBounds(27, 128, 640, 38);
        hardware.Text = "Checking Vulkan support...";
        Controls.Add(hardware);

        Controls.Add(NewLabel("Microphone", 27, 177, 120, 24));
        microphones.SetBounds(150, 174, 390, 28);
        microphones.DropDownStyle = ComboBoxStyle.DropDownList;
        Controls.Add(microphones);
        soundSettings.SetBounds(550, 173, 116, 30);
        soundSettings.Text = "Sound settings";
        soundSettings.Click += delegate { OpenSoundSettings(); };
        Controls.Add(soundSettings);

        Controls.Add(NewLabel("Push-to-talk key", 27, 220, 120, 24));
        hotkey.SetBounds(150, 217, 180, 28);
        hotkey.ReadOnly = true;
        hotkey.Text = "Click, then press a key";
        hotkey.KeyDown += CaptureHotkey;
        Controls.Add(hotkey);

        var modelTitle = NewLabel("Models", 27, 269, 200, 24);
        modelTitle.Font = new Font("Segoe UI Semibold", 11F);
        Controls.Add(modelTitle);
        onlineModels.SetBounds(30, 300, 610, 25);
        onlineModels.Text = "Download the pinned transcription and cleanup models";
        onlineModels.Checked = true;
        onlineModels.CheckedChanged += delegate { UpdateOfflineControls(); };
        Controls.Add(onlineModels);
        offlineModels.SetBounds(30, 329, 610, 25);
        offlineModels.Text = "Use models from an offline release folder";
        offlineModels.CheckedChanged += delegate { UpdateOfflineControls(); };
        Controls.Add(offlineModels);
        offlineDirectory.SetBounds(50, 360, 490, 28);
        offlineDirectory.Enabled = false;
        Controls.Add(offlineDirectory);
        browse.SetBounds(550, 358, 116, 30);
        browse.Text = "Browse...";
        browse.Enabled = false;
        browse.Click += ChooseOfflineDirectory;
        Controls.Add(browse);

        startup.SetBounds(30, 410, 620, 28);
        startup.Text = "Start dictation and local cleanup when I sign in";
        startup.Checked = true;
        Controls.Add(startup);

        progress.SetBounds(30, 455, 636, 20);
        progress.Style = ProgressBarStyle.Continuous;
        Controls.Add(progress);
        status.SetBounds(30, 482, 636, 38);
        status.Text = "Choose a microphone and push-to-talk key.";
        Controls.Add(status);

        install.SetBounds(516, 531, 150, 36);
        install.Text = "Install models";
        install.Click += InstallClicked;
        Controls.Add(install);

        Load += delegate
        {
            PopulateMicrophones();
            Task.Run((Action)CheckHardware);
        };
    }

    private static Label NewLabel(string text, int left, int top, int width, int height)
    {
        var label = new Label();
        label.Text = text;
        label.SetBounds(left, top, width, height);
        return label;
    }

    private void PopulateMicrophones()
    {
        microphones.Items.Clear();
        microphones.Items.Add("Windows default microphone");
        var executable = Path.Combine(baseDirectory, "voxtype.exe");
        if (File.Exists(executable))
        {
            try
            {
                var result = RunProcess(executable, "devices --json", 15000);
                if (result.ExitCode == 0)
                {
                    var devices = new JavaScriptSerializer().Deserialize<string[]>(result.Output);
                    foreach (var device in devices)
                        if (!String.IsNullOrWhiteSpace(device)) microphones.Items.Add(device.Trim());
                    if (microphones.Items.Count > 1) { microphones.SelectedIndex = 0; return; }
                }
            }
            catch { }
        }
        var count = waveInGetNumDevs();
        for (uint index = 0; index < count; index++)
        {
            WaveInCaps caps;
            if (waveInGetDevCaps((UIntPtr)index, out caps,
                    (uint)Marshal.SizeOf(typeof(WaveInCaps))) == 0 &&
                !String.IsNullOrWhiteSpace(caps.ProductName))
            {
                microphones.Items.Add(caps.ProductName.Trim());
            }
        }
        microphones.SelectedIndex = 0;
    }

    private void CheckHardware()
    {
        var server = Path.Combine(baseDirectory, "llama-server.exe");
        var message = "Vulkan device detection unavailable; CPU processing remains available.";
        if (File.Exists(server))
        {
            try
            {
                var result = RunProcess(server, "--list-devices", 15000);
                if (result.ExitCode == 0 && result.Output.IndexOf("Vulkan",
                        StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    message = "Vulkan acceleration is available: " + FirstUsefulLine(result.Output);
                }
                else
                {
                    message = "No Vulkan device was reported; VoxType will use the CPU.";
                }
            }
            catch (Exception exception)
            {
                message = "Hardware check failed; CPU processing remains available. " + exception.Message;
            }
        }
        SetControlText(hardware, message);
    }

    private static string FirstUsefulLine(string text)
    {
        foreach (var line in text.Replace("\r", "").Split('\n'))
        {
            if (!String.IsNullOrWhiteSpace(line)) return line.Trim();
        }
        return "device reported";
    }

    private void CaptureHotkey(object sender, KeyEventArgs args)
    {
        var key = args.KeyCode.ToString().ToUpperInvariant();
        if (key == "MENU") key = "RIGHTALT";
        if (key == "CONTROLKEY") key = "RIGHTCTRL";
        if (key == "SHIFTKEY") key = "RIGHTSHIFT";
        hotkey.Text = key;
        hotkey.Tag = key;
        args.Handled = true;
        args.SuppressKeyPress = true;
    }

    private void UpdateOfflineControls()
    {
        offlineDirectory.Enabled = offlineModels.Checked;
        browse.Enabled = offlineModels.Checked;
    }

    private void ChooseOfflineDirectory(object sender, EventArgs args)
    {
        using (var dialog = new FolderBrowserDialog())
        {
            dialog.Description = "Choose the extracted VoxType offline release folder";
            if (dialog.ShowDialog(this) == DialogResult.OK)
                offlineDirectory.Text = dialog.SelectedPath;
        }
    }

    private void OpenSoundSettings()
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:sound") { UseShellExecute = true }); }
        catch (Exception exception) { MessageBox.Show(this, exception.Message, "Sound settings"); }
    }

    private async void InstallClicked(object sender, EventArgs args)
    {
        if (hotkey.Tag == null)
        {
            MessageBox.Show(this, "Click the push-to-talk field and press the key you want to use.",
                "Choose a key", MessageBoxButtons.OK, MessageBoxIcon.Information);
            hotkey.Focus();
            return;
        }
        if (offlineModels.Checked && !Directory.Exists(offlineDirectory.Text))
        {
            MessageBox.Show(this, "Choose an extracted offline release folder.",
                "Offline models", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        SetBusy(true);
        try
        {
            var modelDirectory = Path.Combine(dataDirectory, "models");
            Directory.CreateDirectory(modelDirectory);
            var models = LoadModels();
            string whisperPath = null;
            string cleanupPath = null;
            for (var index = 0; index < models.Count; index++)
            {
                var model = models[index];
                SetStatus("Preparing " + model.Name + "...");
                progress.Value = (index * 70) / models.Count;
                var destination = Path.Combine(modelDirectory, model.FileName);
                if (offlineModels.Checked)
                {
                    var source = FindOfflineFile(offlineDirectory.Text, model.FileName);
                    await Task.Run(delegate { CopyAndVerify(source, destination, model.Sha256); });
                }
                else
                {
                    await DownloadAndVerify(model, destination);
                }
                if (model.Id == "whisper") whisperPath = destination;
                if (model.Id == "cleanup") cleanupPath = destination;
            }
            progress.Value = 75;
            SetStatus("Applying VoxType settings...");
            var selectedMicrophone = SelectedMicrophone();
            var enableStartup = startup.Checked;
            await Task.Run(delegate
            {
                ApplySettings((string)hotkey.Tag, selectedMicrophone, whisperPath,
                    cleanupPath, enableStartup);
            });
            progress.Value = 90;
            SetStatus("Starting VoxType...");
            StartRuntime();
            progress.Value = 100;
            status.Text = "Setup complete. Hold " + hotkey.Tag + " and speak in any text field.";
            install.Text = "Close";
            install.Click -= InstallClicked;
            install.Click += delegate { Close(); };
            MessageBox.Show(this,
                "VoxType is ready. Open Notepad, hold " + hotkey.Tag +
                ", speak, and release the key to test dictation.",
                "VoxType is ready", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception exception)
        {
            status.Text = "Setup stopped: " + exception.Message;
            MessageBox.Show(this, exception.Message, "VoxType setup",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { SetBusy(false); }
    }

    private string SelectedMicrophone()
    {
        if (microphones.SelectedIndex <= 0) return "";
        return Convert.ToString(microphones.SelectedItem);
    }

    private List<ModelEntry> LoadModels()
    {
        var path = Path.Combine(baseDirectory, "dependencies.lock.json");
        if (!File.Exists(path)) throw new FileNotFoundException("Dependency catalog is missing.", path);
        var serializer = new JavaScriptSerializer();
        var root = serializer.DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>;
        if (root == null || !root.ContainsKey("models"))
            throw new InvalidDataException("Dependency catalog has no models.");
        var values = root["models"] as object[];
        if (values == null) throw new InvalidDataException("Dependency model list is invalid.");
        var result = new List<ModelEntry>();
        foreach (var value in values)
        {
            var item = value as Dictionary<string, object>;
            if (item == null) continue;
            result.Add(new ModelEntry
            {
                Id = RequiredString(item, "id"),
                Name = RequiredString(item, "name"),
                FileName = RequiredString(item, "fileName"),
                Url = RequiredString(item, "url"),
                Sha256 = RequiredString(item, "sha256")
            });
        }
        if (result.Count != 2) throw new InvalidDataException("Expected two pinned models.");
        return result;
    }

    private static string RequiredString(Dictionary<string, object> values, string key)
    {
        object value;
        if (!values.TryGetValue(key, out value) || String.IsNullOrWhiteSpace(Convert.ToString(value)))
            throw new InvalidDataException("Dependency model entry is missing " + key + ".");
        return Convert.ToString(value);
    }

    private async Task DownloadAndVerify(ModelEntry model, string destination)
    {
        if (File.Exists(destination))
        {
            try
            {
                await Task.Run(delegate { VerifyHash(destination, model.Sha256); });
                return;
            }
            catch (InvalidDataException) { File.Delete(destination); }
        }
        var partial = destination + ".partial";
        long existing = File.Exists(partial) ? new FileInfo(partial).Length : 0L;
        var request = (HttpWebRequest)WebRequest.Create(model.Url);
        request.UserAgent = "VoxType-Windows-Setup/1.0";
        if (existing > 0) request.AddRange(existing);
        using (var response = (HttpWebResponse)await request.GetResponseAsync())
        {
            var append = existing > 0 && response.StatusCode == HttpStatusCode.PartialContent;
            var mode = append ? FileMode.Append : FileMode.Create;
            using (var input = response.GetResponseStream())
            using (var output = new FileStream(partial, mode, FileAccess.Write, FileShare.None))
            {
                await input.CopyToAsync(output);
            }
        }
        try
        {
            await Task.Run(delegate { VerifyHash(partial, model.Sha256); });
        }
        catch
        {
            File.Delete(partial);
            throw;
        }
        if (File.Exists(destination)) File.Delete(destination);
        File.Move(partial, destination);
    }

    private static string FindOfflineFile(string root, string name)
    {
        var direct = Path.Combine(root, name);
        if (File.Exists(direct)) return direct;
        var models = Path.Combine(root, "models", name);
        if (File.Exists(models)) return models;
        throw new FileNotFoundException("Offline release is missing " + name + ".");
    }

    private static void CopyAndVerify(string source, string destination, string expectedHash)
    {
        VerifyHash(source, expectedHash);
        var temporary = destination + ".partial";
        File.Copy(source, temporary, true);
        VerifyHash(temporary, expectedHash);
        if (File.Exists(destination)) File.Delete(destination);
        File.Move(temporary, destination);
    }

    private static void VerifyHash(string path, string expected)
    {
        string actual;
        using (var stream = File.OpenRead(path))
        using (var sha = SHA256.Create())
            actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        if (!String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException(Path.GetFileName(path) + " failed its SHA-256 check.");
    }

    private void ApplySettings(string key, string microphone, string whisper,
        string cleanup, bool enableStartup)
    {
        var script = Path.Combine(baseDirectory, "windows", "voxtype-setup.ps1");
        var arguments = new StringBuilder();
        arguments.Append("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
        arguments.Append(Quote(script)).Append(" -Hotkey ").Append(Quote(key));
        arguments.Append(" -WhisperModelPath ").Append(Quote(whisper));
        arguments.Append(" -CleanupModelPath ").Append(Quote(cleanup));
        if (!String.IsNullOrWhiteSpace(microphone))
            arguments.Append(" -AudioDevice ").Append(Quote(microphone));
        arguments.Append(enableStartup ? " -EnableStartup" : " -DisableStartup");
        arguments.Append(" -SetupVad");
        var result = RunProcess(Path.Combine(Environment.SystemDirectory,
            @"WindowsPowerShell\v1.0\powershell.exe"), arguments.ToString(), 300000);
        if (result.ExitCode != 0)
            throw new InvalidOperationException("VoxType rejected its settings. " + result.Output);
    }

    private void StartRuntime()
    {
        StartDetached(Path.Combine(baseDirectory, "voxtype.exe"), "");
        StartDetached(Path.Combine(baseDirectory, "voxtype-cleanup-server.exe"), "");
    }

    private static void StartDetached(string executable, string arguments)
    {
        if (!File.Exists(executable)) return;
        Process.Start(new ProcessStartInfo
        {
            FileName = executable,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        });
    }

    private static ProcessResult RunProcess(string executable, string arguments, int timeout)
    {
        var start = new ProcessStartInfo
        {
            FileName = executable,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var process = Process.Start(start))
        {
            if (process == null) throw new InvalidOperationException("Could not start " + executable);
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeout))
            {
                try { process.Kill(); } catch { }
                throw new TimeoutException(Path.GetFileName(executable) + " timed out.");
            }
            return new ProcessResult(process.ExitCode,
                stdout.GetAwaiter().GetResult() + stderr.GetAwaiter().GetResult());
        }
    }

    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            return value;
        var result = new StringBuilder("\"");
        var slashes = 0;
        foreach (var character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') result.Append('\\', slashes * 2 + 1).Append('"');
            else result.Append('\\', slashes).Append(character);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    private void SetBusy(bool busy)
    {
        install.Enabled = !busy;
        onlineModels.Enabled = !busy;
        offlineModels.Enabled = !busy;
        microphones.Enabled = !busy;
        hotkey.Enabled = !busy;
        startup.Enabled = !busy;
        browse.Enabled = !busy && offlineModels.Checked;
        offlineDirectory.Enabled = !busy && offlineModels.Checked;
        UseWaitCursor = busy;
    }

    private void SetStatus(string value) { SetControlText(status, value); }

    private static void SetControlText(Control control, string value)
    {
        if (control.InvokeRequired)
            control.BeginInvoke((Action)delegate { control.Text = value; });
        else
            control.Text = value;
    }

    private sealed class ModelEntry
    {
        public string Id;
        public string Name;
        public string FileName;
        public string Url;
        public string Sha256;
    }

    private sealed class ProcessResult
    {
        public readonly int ExitCode;
        public readonly string Output;
        public ProcessResult(int exitCode, string output) { ExitCode = exitCode; Output = output; }
    }
}

internal static class ConfigureLauncher
{
    [STAThread]
    public static int Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try
        {
            Application.Run(new ConfigureForm());
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "VoxType setup", MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }
}
