using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
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
    private readonly CheckBox parakeet = new CheckBox();
    private bool parakeetOptional;
    private readonly Label hardware = new Label();
    private readonly Label status = new Label();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly Button install = new Button();
    private readonly Button soundSettings = new Button();
    private readonly Label summary = new Label();
    private readonly ComboBox cleanup = new ComboBox();
    private List<ModelEntry> catalog;

    // The speech models a catalog pins, by id, and the voxtype-setup.ps1 flag that sets each.
    // Windows pins both, Whisper for dictation and Parakeet for transcribing recordings;
    // older catalogs pin one, which then does both.
    private static readonly Dictionary<string, string> SpeechFlags = new Dictionary<string, string>
    {
        { "parakeet", "-ParakeetModelPath" },
        { "whisper", "-WhisperModelPath" }
    };

    // The cleanup choices offered here, as chains for voxtype-setup.ps1 -CleanupBackend.
    private static readonly string[] CleanupChains = { "local", "pi", "pi,local" };
    private static readonly string[] CleanupLabels =
    {
        "Local Qwen only (2.5 GB download; text stays on this PC)",
        "Pi (hosted; sends transcript text)",
        "Pi, then local Qwen if Pi is unavailable"
    };

    public ConfigureForm()
    {
        baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        dataDirectory = Path.Combine(Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData), "VoxType");
        Text = "Set up VoxType";
        ClientSize = new Size(700, 665);
        MinimumSize = new Size(716, 704);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9F);

        var title = NewLabel("VoxType local dictation", 24, 18, 640, 35);
        title.Font = new Font("Segoe UI Semibold", 20F);
        Controls.Add(title);
        summary.SetBounds(27, 58, 640, 40);
        Controls.Add(summary);

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

        Controls.Add(NewLabel("Cleanup", 27, 266, 120, 24));
        cleanup.SetBounds(150, 263, 516, 28);
        cleanup.DropDownStyle = ComboBoxStyle.DropDownList;
        cleanup.Items.AddRange(CleanupLabels);
        cleanup.SelectedIndexChanged += delegate { UpdateSummary(); };
        Controls.Add(cleanup);

        var modelTitle = NewLabel("Models", 27, 314, 200, 24);
        modelTitle.Font = new Font("Segoe UI Semibold", 11F);
        Controls.Add(modelTitle);
        onlineModels.SetBounds(30, 345, 610, 25);
        onlineModels.Text = "Download the pinned models";
        onlineModels.Checked = true;
        onlineModels.CheckedChanged += delegate { UpdateOfflineControls(); };
        Controls.Add(onlineModels);
        offlineModels.SetBounds(30, 374, 610, 25);
        offlineModels.Text = "Use models from an offline release folder";
        offlineModels.CheckedChanged += delegate { UpdateOfflineControls(); };
        Controls.Add(offlineModels);
        offlineDirectory.SetBounds(50, 405, 490, 28);
        offlineDirectory.Enabled = false;
        Controls.Add(offlineDirectory);
        browse.SetBounds(550, 403, 116, 30);
        browse.Text = "Browse...";
        browse.Enabled = false;
        browse.Click += ChooseOfflineDirectory;
        Controls.Add(browse);
        // Dictation runs on Whisper, so Parakeet's download is offered and never assumed.
        parakeet.SetBounds(30, 445, 636, 28);
        parakeet.Visible = false;
        parakeet.CheckedChanged += delegate { UpdateSummary(); };
        Controls.Add(parakeet);

        startup.SetBounds(30, 485, 620, 28);
        startup.Text = "Start VoxType when I sign in";
        startup.Checked = true;
        Controls.Add(startup);

        progress.SetBounds(30, 530, 636, 20);
        progress.Style = ProgressBarStyle.Continuous;
        Controls.Add(progress);
        status.SetBounds(30, 557, 636, 38);
        status.Text = "Choose a microphone and push-to-talk key.";
        Controls.Add(status);

        install.SetBounds(516, 606, 150, 36);
        install.Text = "Install models";
        install.Click += InstallClicked;
        Controls.Add(install);

        try { catalog = LoadModels(); }
        catch (Exception) { catalog = null; }
        var parakeetModel = OptionalParakeet(catalog);
        if (parakeetModel != null)
        {
            parakeetOptional = true;
            parakeet.Text = "Also download Parakeet Ultra, for transcribing recordings (" +
                ResumableDownload.FormatBytes(parakeetModel.Size) + ")";
            parakeet.Visible = true;
            // Ticked when it is already here, so running setup again keeps it.
            parakeet.Checked = ModelPresent(parakeetModel);
        }
        // A fresh install starts on local cleanup, the same chain VoxType uses when no
        // choice is recorded; a recorded choice that is offered here is kept.
        var recorded = Array.IndexOf(CleanupChains, CleanupBackend.ReadRecorded(dataDirectory));
        cleanup.SelectedIndex = recorded >= 0 ? recorded : 0;
        UpdateSummary();

        Load += delegate
        {
            PopulateMicrophones();
            Task.Run((Action)CheckHardware);
        };
    }

    private string SelectedChain()
    {
        return CleanupChains[Math.Max(0, cleanup.SelectedIndex)];
    }

    private bool ModelNeeded(ModelEntry model, string chain)
    {
        return ModelNeeded(model.Id, chain, parakeetOptional, parakeet.Checked);
    }

    // Which pinned models setup fetches: Qwen only for a chain that uses local cleanup, and
    // Parakeet only when asked for, unless it is the catalog's one speech model.
    internal static bool ModelNeeded(string id, string chain, bool parakeetOptional, bool parakeetChosen)
    {
        if (id == "cleanup") return CleanupBackend.ContainsLocal(chain);
        if (id == "parakeet" && parakeetOptional) return parakeetChosen;
        return true;
    }

    // Parakeet is optional where the catalog also pins Whisper for dictation.
    private static ModelEntry OptionalParakeet(List<ModelEntry> models)
    {
        if (models == null || !models.Exists(delegate(ModelEntry m) { return m.Id == "whisper"; }))
            return null;
        return models.Find(delegate(ModelEntry m) { return m.Id == "parakeet"; });
    }

    // A model already on this PC by its files' names and sizes; setup still checks digests.
    private bool ModelPresent(ModelEntry model)
    {
        var folder = Path.Combine(dataDirectory, "models");
        if (model.Folder != null) folder = Path.Combine(folder, model.Folder);
        foreach (var file in model.Files)
        {
            var info = new FileInfo(Path.Combine(folder, file.FileName));
            if (!info.Exists || info.Length != file.Size) return false;
        }
        return true;
    }

    // The header says where text goes for the chosen cleanup and how much disk the
    // models it needs take, from the pinned catalog.
    private void UpdateSummary()
    {
        var chain = SelectedChain();
        var hosted = chain.Split(',')[0] == "pi";
        var local = CleanupBackend.ContainsLocal(chain);
        string text;
        if (!hosted)
            text = "Speech and cleanup stay on this PC.";
        else if (local)
            text = "Speech is transcribed on this PC. Cleanup sends the transcript text over " +
                "the internet to a hosted model through Pi; local Qwen cleans it only when Pi " +
                "is unavailable.";
        else
            text = "Speech is transcribed on this PC. Cleanup sends the transcript text over " +
                "the internet to a hosted model through Pi.";
        if (hosted && !OnPath("pi"))
            text += local ? " Pi is not installed yet, so local Qwen does the cleanup until it is." :
                " Pi is not installed yet, so text is typed without cleanup until it is.";
        var bytes = RequiredModelBytes(chain);
        if (bytes > 0)
            text += " The models need " + ResumableDownload.FormatBytes(bytes) + " of disk space.";
        summary.Text = text;
    }

    private long RequiredModelBytes(string chain)
    {
        if (catalog == null) return 0;
        long total = 0;
        foreach (var model in catalog)
        {
            if (!ModelNeeded(model, chain)) continue;
            if (model.Size <= 0) return 0;
            total += model.Size;
        }
        return total;
    }

    private static bool OnPath(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(';'))
        {
            if (directory.Trim().Length == 0) continue;
            foreach (var extension in new[] { ".exe", ".cmd", ".bat", ".com" })
            {
                try
                {
                    if (File.Exists(Path.Combine(directory.Trim(), name + extension))) return true;
                }
                catch (ArgumentException) { }
            }
        }
        return false;
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
            var chain = SelectedChain();
            // The Qwen cleanup model is fetched only for a chain that can use it.
            var models = new List<ModelEntry>();
            foreach (var entry in LoadModels())
                if (ModelNeeded(entry, chain)) models.Add(entry);
            var speechModels = new List<KeyValuePair<string, string>>();
            string cleanupPath = null;
            for (var index = 0; index < models.Count; index++)
            {
                var model = models[index];
                SetStatus("Preparing " + model.Name + "...");
                progress.Value = (index * 70) / models.Count;
                // A model of several files (Parakeet) keeps them in its own folder.
                var target = model.Folder == null ? modelDirectory :
                    Path.Combine(modelDirectory, model.Folder);
                Directory.CreateDirectory(target);
                long before = 0;
                foreach (var file in model.Files)
                {
                    var destination = Path.Combine(target, file.FileName);
                    if (offlineModels.Checked)
                    {
                        var source = FindOfflineFile(offlineDirectory.Text, model.Folder, file.FileName);
                        await Task.Run(delegate { CopyAndVerify(source, destination, file.Sha256); });
                    }
                    else
                    {
                        await DownloadAndVerify(model, file, destination, before, index, models.Count);
                    }
                    before += file.Size;
                }
                var path = model.Folder == null ? Path.Combine(target, model.Files[0].FileName) : target;
                if (SpeechFlags.ContainsKey(model.Id))
                    speechModels.Add(new KeyValuePair<string, string>(SpeechFlags[model.Id], path));
                if (model.Id == "cleanup") cleanupPath = path;
            }
            progress.Value = 75;
            SetStatus("Applying VoxType settings...");
            var selectedMicrophone = SelectedMicrophone();
            var enableStartup = startup.Checked;
            await Task.Run(delegate
            {
                ApplySettings((string)hotkey.Tag, selectedMicrophone, speechModels,
                    cleanupPath, enableStartup, chain);
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
        var speech = 0;
        var cleanups = 0;
        foreach (var value in values)
        {
            var item = value as Dictionary<string, object>;
            if (item == null) continue;
            var entry = new ModelEntry
            {
                Id = RequiredString(item, "id"),
                Name = RequiredString(item, "name"),
                Files = new List<ModelFile>()
            };
            // A model of several files lists them under files, kept in its own folder;
            // a model of one file is that file.
            object listed;
            if (item.TryGetValue("files", out listed))
            {
                entry.Folder = RequiredString(item, "directory");
                if (entry.Folder.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                        entry.Folder.Trim('.').Length == 0)
                    throw new InvalidDataException("Dependency model folder is invalid.");
                var files = listed as object[];
                if (files == null || files.Length == 0)
                    throw new InvalidDataException("Dependency model file list is invalid.");
                foreach (var file in files)
                {
                    var fields = file as Dictionary<string, object>;
                    if (fields == null) throw new InvalidDataException("Dependency model file is invalid.");
                    entry.Files.Add(NewModelFile(fields));
                }
            }
            else
            {
                entry.Files.Add(NewModelFile(item));
            }
            foreach (var file in entry.Files)
            {
                if (file.Size <= 0) { entry.Size = 0; break; }
                entry.Size += file.Size;
            }
            if (SpeechFlags.ContainsKey(entry.Id)) speech++;
            if (entry.Id == "cleanup") cleanups++;
            result.Add(entry);
        }
        if (speech < 1 || speech > SpeechFlags.Count || cleanups != 1 || result.Count != speech + cleanups)
            throw new InvalidDataException("Expected the cleanup model and one or two speech models.");
        return result;
    }

    private static ModelFile NewModelFile(Dictionary<string, object> fields)
    {
        return new ModelFile
        {
            FileName = RequiredString(fields, "fileName"),
            Url = RequiredString(fields, "url"),
            Sha256 = RequiredString(fields, "sha256"),
            Size = OptionalSize(fields)
        };
    }

    private static string RequiredString(Dictionary<string, object> values, string key)
    {
        object value;
        if (!values.TryGetValue(key, out value) || String.IsNullOrWhiteSpace(Convert.ToString(value)))
            throw new InvalidDataException("Dependency model entry is missing " + key + ".");
        return Convert.ToString(value);
    }

    // The catalog's byte count lets an already complete .partial be verified without a
    // request. Older catalogs omit it; the download then learns the length from the server.
    private static long OptionalSize(Dictionary<string, object> values)
    {
        object value;
        if (!values.TryGetValue("size", out value) || value == null) return 0;
        long size;
        if (!Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
                NumberStyles.None, CultureInfo.InvariantCulture, out size) || size <= 0)
            throw new InvalidDataException("Dependency model entry has an invalid size.");
        return size;
    }

    // Downloads run on a worker thread through ResumableDownload, which resumes .partial
    // files, recovers a partial that is already complete, restarts stalled connections and
    // renames only after the pinned SHA-256 matches.
    // A model of several files shows one progress over all of them: `before` is what
    // its earlier files took.
    private async Task DownloadAndVerify(ModelEntry model, ModelFile file, string destination,
        long before, int index, int count)
    {
        if (File.Exists(destination))
        {
            try
            {
                SetStatus("Checking " + model.Name + " (SHA-256)...");
                await Task.Run(delegate { VerifyHash(destination, file.Sha256); });
                return;
            }
            catch (InvalidDataException) { File.Delete(destination); }
        }
        var download = new ResumableDownload
        {
            Url = file.Url,
            Destination = destination,
            Sha256 = file.Sha256,
            ExpectedSize = file.Size,
            UserAgent = "VoxType-Windows-Setup/1.0",
            Progress = delegate(DownloadPhase phase, long received, long total)
            {
                if (model.Size > 0) { received += before; total = model.Size; }
                ShowDownloadProgress(model.Name, phase, received, total, index, count);
            }
        };
        await Task.Run((Action)download.Run);
    }

    // Model downloads share the first 70% of the bar, one equal slice per model.
    private void ShowDownloadProgress(string name, DownloadPhase phase, long received,
        long total, int index, int count)
    {
        string text;
        if (phase == DownloadPhase.Verifying)
            text = "Checking " + name + " (SHA-256)...";
        else if (phase == DownloadPhase.Resuming)
            text = "The " + name + " download stalled at " +
                ResumableDownload.FormatBytes(received) + "; resuming...";
        else
            text = "Downloading " + name + ": " + ResumableDownload.Describe(received, total);
        var span = 70 / count;
        var value = index * span;
        if (total > 0) value += (int)((long)span * Math.Min(received, total) / total);
        RunOnUi(delegate
        {
            status.Text = text;
            progress.Value = Math.Max(progress.Minimum, Math.Min(progress.Maximum, value));
        });
    }

    private void RunOnUi(Action action)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try
        {
            if (InvokeRequired) BeginInvoke(action);
            else action();
        }
        catch (InvalidOperationException) { }
    }

    // A file of a model with its own folder is looked for in that folder.
    private static string FindOfflineFile(string root, string folder, string name)
    {
        var relative = folder == null ? name : Path.Combine(folder, name);
        var direct = Path.Combine(root, relative);
        if (File.Exists(direct)) return direct;
        var models = Path.Combine(root, "models", relative);
        if (File.Exists(models)) return models;
        throw new FileNotFoundException("Offline release is missing " + relative + ".");
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
        if (!ResumableDownload.HashMatches(path, expected))
            throw new InvalidDataException(Path.GetFileName(path) + " failed its SHA-256 check.");
    }

    private void ApplySettings(string key, string microphone, List<KeyValuePair<string, string>> speechModels,
        string cleanupModel, bool enableStartup, string chain)
    {
        var script = Path.Combine(baseDirectory, "windows", "voxtype-setup.ps1");
        var arguments = new StringBuilder();
        arguments.Append("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
        arguments.Append(Quote(script)).Append(" -Hotkey ").Append(Quote(key));
        foreach (var speech in speechModels)
            arguments.Append(" ").Append(speech.Key).Append(" ").Append(Quote(speech.Value));
        if (!String.IsNullOrEmpty(cleanupModel))
            arguments.Append(" -CleanupModelPath ").Append(Quote(cleanupModel));
        arguments.Append(" -CleanupBackend ").Append(Quote(chain));
        if (!String.IsNullOrWhiteSpace(microphone))
            arguments.Append(" -AudioDevice ").Append(Quote(microphone));
        arguments.Append(enableStartup ? " -EnableStartup" : " -DisableStartup");
        arguments.Append(" -SetupVad");
        var result = RunProcess(Path.Combine(Environment.SystemDirectory,
            @"WindowsPowerShell\v1.0\powershell.exe"), arguments.ToString(), 300000);
        if (result.ExitCode != 0)
            throw new InvalidOperationException("VoxType rejected its settings. " + result.Output);
    }

    // The GPU-resident cleanup server runs only for a chain that uses it; switching away
    // from local stops this package's copy instead of leaving it holding memory.
    private void StartRuntime()
    {
        StartDetached(Path.Combine(baseDirectory, "voxtype.exe"), "");
        if (CleanupBackend.WantsLocalServer(dataDirectory))
            StartDetached(Path.Combine(baseDirectory, "voxtype-cleanup-server.exe"), "");
        else
            StopPackagedProcesses("voxtype-cleanup-server", "llama-server");
    }

    private void StopPackagedProcesses(params string[] names)
    {
        foreach (var name in names)
        {
            foreach (var process in Process.GetProcessesByName(name))
            {
                using (process)
                {
                    try
                    {
                        var file = process.MainModule.FileName;
                        if (file.StartsWith(baseDirectory, StringComparison.OrdinalIgnoreCase))
                            process.Kill();
                    }
                    catch (Exception) { }
                }
            }
        }
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
        cleanup.Enabled = !busy;
        hotkey.Enabled = !busy;
        startup.Enabled = !busy;
        parakeet.Enabled = !busy;
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
        public string Folder;
        public List<ModelFile> Files;
        public long Size;
    }

    private sealed class ModelFile
    {
        public string FileName;
        public string Url;
        public string Sha256;
        public long Size;
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
