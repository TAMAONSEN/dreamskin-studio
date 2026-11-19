using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;
using System.Windows.Threading;
using Microsoft.Win32;

namespace DreamSkinStudio
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--self-test") { StudioSelfTest.Run(args); return; }
            if (args.Length == 1 && args[0] == "--open-codex")
            {
                try { EngineBridge.Call("OpenCodex"); }
                catch (Exception ex)
                {
                    MessageBox.Show(ex.Message, "DreamSkin · 打开 Codex", MessageBoxButton.OK, MessageBoxImage.Information);
                    Environment.ExitCode = 1;
                }
                return;
            }
            string sid = WindowsIdentity.GetCurrent().User.Value;
            string instanceName = "Local\\CodexDreamSkin." + sid + ".ThemeManager";
            using (var instance = new Mutex(false, instanceName))
            using (var activation = new EventWaitHandle(false, EventResetMode.AutoReset, instanceName + ".Activate"))
            using (var closeRequest = new EventWaitHandle(false, EventResetMode.AutoReset, instanceName + ".Close"))
            {
                bool primary = false;
                try { primary = instance.WaitOne(0); } catch (AbandonedMutexException) { primary = true; }
                if (!primary) { activation.Set(); return; }
                try
                {
                    var app = new Application();
                    app.DispatcherUnhandledException += delegate(object sender, DispatcherUnhandledExceptionEventArgs e)
                    {
                        try { File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "studio-crash.log"), DateTime.Now + " " + e.Exception + Environment.NewLine, Encoding.UTF8); } catch { }
                        MessageBox.Show("界面操作遇到问题：" + e.Exception.Message, "DreamSkin Studio", MessageBoxButton.OK, MessageBoxImage.Warning);
                        e.Handled = true;
                    };
                    Window window;
                    using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DreamSkinStudio.MainWindow.xaml"))
                        window = (Window)XamlReader.Load(stream);
                    UiPalette.Load(window, EngineBridge.StateRoot);
                    var controller = new StudioController(window);
                    var activationTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
                    activationTimer.Tick += delegate
                    {
                        if (closeRequest.WaitOne(0)) { window.Close(); return; }
                        if (!activation.WaitOne(0)) return;
                        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
                        window.Show(); window.Activate();
                    };
                    window.Loaded += delegate { activationTimer.Start(); };
                    window.Closed += delegate { activationTimer.Stop(); controller.Dispose(); };
                    app.Run(window);
                }
                catch (Exception ex)
                {
                    try { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "studio-start-error.log"), ex.ToString(), Encoding.UTF8); } catch { }
                    MessageBox.Show("管理器无法启动：" + ex.Message, "DreamSkin Studio", MessageBoxButton.OK, MessageBoxImage.Error);
                }
                finally { instance.ReleaseMutex(); }
            }
        }
    }

    internal sealed class ThemeInfo
    {
        public string Id = "", Name = "", Directory = "", MediaPath = "", MediaType = "image";
        public bool IsActive;
        public double Reveal = 75;
        public static ThemeInfo From(Dictionary<string, object> data)
        {
            return new ThemeInfo { Id = Json.Text(data, "id"), Name = Json.Text(data, "name"), Directory = Json.Text(data, "path"),
                MediaPath = Json.Text(data, "mediaPath"), MediaType = Json.Text(data, "mediaType", "image"),
                IsActive = Json.Bool(data, "isActive"), Reveal = Json.Number(data, "reveal", 75) };
        }
    }

    internal static class Json
    {
        public static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        public static object Get(Dictionary<string, object> data, string key) { object value; return data.TryGetValue(key, out value) ? value : null; }
        public static string Text(Dictionary<string, object> data, string key, string fallback = "") { return Convert.ToString(Get(data, key), CultureInfo.InvariantCulture) ?? fallback; }
        public static bool Bool(Dictionary<string, object> data, string key) { object value = Get(data, key); return value != null && Convert.ToBoolean(value, CultureInfo.InvariantCulture); }
        public static double Number(Dictionary<string, object> data, string key, double fallback = 0) { object value = Get(data, key); double result; return value != null && double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Any, CultureInfo.InvariantCulture, out result) ? result : fallback; }
    }

    internal static class EngineBridge
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool AllowSetForegroundWindow(int processId);
        public static string BaseDirectory { get { return AppDomain.CurrentDomain.BaseDirectory; } }
        public static string StateRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexDreamSkin"); } }
        public static string Quote(string value)
        {
            if (value == null) value = "";
            var b = new StringBuilder("\""); int slashes = 0;
            foreach (char ch in value)
            {
                if (ch == '\\') { slashes++; continue; }
                if (ch == '"') { b.Append('\\', slashes * 2 + 1); b.Append(ch); slashes = 0; continue; }
                b.Append('\\', slashes); slashes = 0; b.Append(ch);
            }
            b.Append('\\', slashes * 2); b.Append('"'); return b.ToString();
        }
        public static Dictionary<string, object> Call(string action, params string[] arguments)
        {
            return CallScript("studio-bridge.ps1", action, arguments);
        }
        public static Dictionary<string, object> CallLink(string action, params string[] arguments)
        {
            return CallScript("wallpaper-link.ps1", action, arguments);
        }
        public static Dictionary<string, object> RecordWallpaper(string projectPath)
        {
            return CallScript("record-wallpaper.ps1", "Record", "-ProjectPath", projectPath);
        }
        private static Dictionary<string, object> CallScript(string leaf, string action, params string[] arguments)
        {
            string script = Path.Combine(BaseDirectory, "backend", leaf);
            if (!File.Exists(script)) throw new IOException("找不到管理器后端，请从完整文件夹启动程序。");
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string ps = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            var info = new ProcessStartInfo(ps) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = BaseDirectory };
            var all = new List<string> { "-NoProfile", "-STA", "-ExecutionPolicy", "RemoteSigned", "-File", script, "-Action", action };
            all.AddRange(arguments);
            info.Arguments = String.Join(" ", all.Select(Quote).ToArray());
            info.EnvironmentVariables["PSModulePath"] = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "Modules") + ";" + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules");
            using (var p = new Process { StartInfo = info })
            {
                p.Start();
                if (action == "OpenCodex" || action == "Apply" || action == "ApplyTheme" || action == "Resume")
                    // Keep the manager visible until this grant. The backend
                    // selects and activates the verified Codex window itself.
                    AllowSetForegroundWindow(p.Id);
                var output = p.StandardOutput.ReadToEndAsync(); var error = p.StandardError.ReadToEndAsync();
                p.WaitForExit(); Task.WaitAll(output, error);
                string text = output.Result.Trim().TrimStart('\uFEFF');
                Dictionary<string, object> response;
                try { response = new JavaScriptSerializer { MaxJsonLength = 4194304 }.Deserialize<Dictionary<string, object>>(text); }
                catch { throw new InvalidOperationException("操作未返回有效结果。" + Short(error.Result.Length > 0 ? error.Result : text)); }
                if (response == null || !Json.Bool(response, "ok")) throw new InvalidOperationException(response == null ? "操作结果为空。" : Json.Text(response, "error", "操作失败，请查看诊断。"));
                return Json.Map(Json.Get(response, "data"));
            }
        }
        private static string Short(string text) { return text.Length > 400 ? text.Substring(text.Length - 400) : text; }
    }

    internal sealed class StudioController : IDisposable
    {
        private readonly Window window;
        private readonly Dictionary<string, Button> buttons = new Dictionary<string, Button>();
        private readonly DispatcherTimer refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(12) };
        private readonly DispatcherTimer revealTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(650) };
        private ThemeInfo active, selected;
        private List<ThemeInfo> themes = new List<ThemeInfo>();
        private bool busy, refreshing, loading, sliderEditing, previewPlaying, paused, closingRequested, disposed;
        private bool uiActionActive;
        private int page;
        private int? pendingReveal;
        private string activePreviewPath = "";
        private readonly StringBuilder log = new StringBuilder();
        private readonly bool testMode;
        private readonly WallpaperLinkPanel wallpaperLink;
        private readonly Ambience ambience;
        private Color[] activeSeeds, selectedSeeds;
        // Documentation screenshots: the self-test can show sample pictures and neutral
        // names in place of the wallpapers that happen to be in this computer's library.
        private readonly List<string> sampleArt = new List<string>();
        private readonly Dictionary<string, int> sampleSlots = new Dictionary<string, int>();
        private static readonly string[] SampleNames = { "极光", "暮色", "深海", "薄荷", "余烬", "星云", "晨雾", "霓虹", "琥珀", "青岚", "樱时", "夜航", "苔原" };
        private string activeSeedPath = "", selectedSeedPath = "";
        private T Find<T>(string name) where T : class { return window.FindName(name) as T; }
        private TextBlock Label(string name) { return Find<TextBlock>(name); }
        private Button Button(string name) { return Find<Button>(name); }
        private Slider Reveal { get { return Find<Slider>("RevealSlider"); } }

        public StudioController(Window target, bool readOnlyTest = false, string sampleFolder = null)
        {
            window = target; testMode = readOnlyTest;
            if (readOnlyTest && sampleFolder != null) sampleArt.AddRange(Directory.GetFiles(sampleFolder, "*.jpg").OrderBy(file => file, StringComparer.OrdinalIgnoreCase));
            ambience = new Ambience(window);
            using (var artwork = Assembly.GetExecutingAssembly().GetManifestResourceStream("DreamSkinStudio.Mark.png"))
            {
                var mark = new BitmapImage();
                mark.BeginInit(); mark.CacheOption = BitmapCacheOption.OnLoad; mark.StreamSource = artwork; mark.EndInit(); mark.Freeze();
                window.Icon = mark;
                Find<Image>("StudioMark").Source = mark;
            }
            wallpaperLink = new WallpaperLinkPanel(async delegate { await RefreshAll(true); }, AddLog, readOnlyTest,
                delegate { return !busy && !refreshing && !sliderEditing && !pendingReveal.HasValue && !uiActionActive; },
                delegate(bool value) { SetBusy(value, value ? "正在同步 Wallpaper Engine…" : null); if (!value && closingRequested && !pendingReveal.HasValue) window.Close(); });
            Find<StackPanel>("WallpaperLinkHost").Children.Add(wallpaperLink);
            foreach (string name in new[] { "ApplyButton", "ApplySelectedButton", "RefreshButton", "AddMediaButton", "ChangeMediaButton", "ImportZipButton", "PauseSkinButton", "SaveThemeButton", "RestoreButton", "DiagnoseButton", "Reveal60", "Reveal75", "Reveal90", "ColorsButton", "SettingsColorsButton" }) buttons[name] = Button(name);
            Click("MinimizeButton", delegate { window.WindowState = WindowState.Minimized; });
            Click("MaximizeButton", delegate { window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; });
            Click("CloseButton", delegate { window.Close(); });
            Click("NavHome", delegate { ShowPage(0); }); Click("NavLibrary", delegate { ShowPage(1); }); Click("NavSettings", delegate { ShowPage(2); });
            Click("ShowLibraryButton", delegate { ShowPage(1); });
            Click("OpenLibraryButton", delegate { OpenFolder(Path.Combine(EngineBridge.StateRoot, "themes")); });
            Click("OpenEngineFolderButton", delegate { OpenFolder(Path.Combine(EngineBridge.StateRoot, "engine")); });
            Click("OpenLogsButton", delegate { OpenFolder(Path.Combine(EngineBridge.BaseDirectory, "logs")); });
            Click("OpenSelectedButton", delegate { if (selected != null) OpenFolder(selected.Directory); });
            AsyncClick("RefreshButton", async delegate { await RefreshAll(true); });
            AsyncClick("ApplyButton", async delegate {
                if (page == 1 && selected != null) await ApplySelected();
                else if (page == 2) await Execute("Apply", "正在重新应用当前背景…");
                else await Execute("OpenCodex", "正在打开带背景的 Codex…");
            });
            AsyncClick("ApplySelectedButton", ApplySelected);
            AsyncClick("RenameSelectedButton", RenameSelected);
            AsyncClick("RecycleSelectedButton", RecycleSelected);
            AsyncClick("AddMediaButton", AddMedia); AsyncClick("ChangeMediaButton", AddMedia);
            AsyncClick("ImportZipButton", ImportZip); AsyncClick("SaveThemeButton", SaveTheme);
            AsyncClick("PauseSkinButton", async delegate { await Execute(paused ? "Resume" : "Pause", paused ? "正在恢复显示背景…" : "正在暂停背景…"); });
            AsyncClick("RestoreButton", async delegate
            {
                if (MessageBox.Show(window, "恢复 Codex 官方外观？\n\n已保存的主题和媒体会保留。若需要重启，接下来会再弹出引擎确认。", "恢复官方外观", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) == MessageBoxResult.OK)
                    await Execute("Restore", "正在恢复官方外观…");
            });
            AsyncClick("DiagnoseButton", Diagnose);
            AsyncClick("ColorsButton", EditColors); AsyncClick("SettingsColorsButton", EditColors);
            Click("Reveal60", delegate { QueueReveal(60); }); Click("Reveal75", delegate { QueueReveal(75); }); Click("Reveal90", delegate { QueueReveal(90); });
            Click("PreviewOriginalButton", delegate { Find<CheckBox>("SimulateOpacity").IsChecked = false; UpdateShade(); });
            Click("PreviewEffectButton", delegate { Find<CheckBox>("SimulateOpacity").IsChecked = true; UpdateShade(); });
            Click("ClearSearchButton", delegate { Find<TextBox>("SearchBox").Text = ""; });
            Reveal.PreviewMouseDown += delegate { sliderEditing = true; };
            Reveal.PreviewMouseUp += delegate { sliderEditing = false; if (pendingReveal.HasValue) { revealTimer.Stop(); revealTimer.Start(); } };
            Reveal.ValueChanged += delegate
            {
                Label("RevealValue").Text = Math.Round(Reveal.Value).ToString(CultureInfo.InvariantCulture) + "%";
                UpdateShade();
                UpdatePresets();
                if (loading || active == null) return;
                pendingReveal = (int)Math.Round(Reveal.Value); revealTimer.Stop(); if (!sliderEditing) revealTimer.Start();
            };
            revealTimer.Tick += async delegate { revealTimer.Stop(); if (!busy && pendingReveal.HasValue) { int value = pendingReveal.Value; pendingReveal = null; await Execute("SetReveal", "正在保存背景可见度…", "-Percent", value.ToString(CultureInfo.InvariantCulture)); } else if (pendingReveal.HasValue) revealTimer.Start(); };
            Find<CheckBox>("SimulateOpacity").Click += delegate { UpdateShade(); };
            Find<TextBox>("SearchBox").TextChanged += delegate { bool empty = Find<TextBox>("SearchBox").Text.Length == 0; Label("SearchHint").Visibility = empty ? Visibility.Visible : Visibility.Collapsed; Button("ClearSearchButton").Visibility = empty ? Visibility.Collapsed : Visibility.Visible; RenderLibrary(); };
            Find<ListBox>("ThemeList").SelectionChanged += delegate
            {
                var item = Find<ListBox>("ThemeList").SelectedItem as ListBoxItem;
                selected = item == null ? null : item.Tag as ThemeInfo; ShowSelected();
            };
            Find<CheckBox>("AutoStartCheck").Click += async delegate
            {
                if (loading) return;
                await Execute("SetAutoStart", "正在保存登录启动设置…", "-Enabled", Find<CheckBox>("AutoStartCheck").IsChecked == true ? "true" : "false", "-Path", Assembly.GetExecutingAssembly().Location);
            };
            Click("PreviewPlayButton", delegate
            {
                var video = Find<MediaElement>("ArtworkVideo"); if (previewPlaying) video.Pause(); else video.Play();
                previewPlaying = !previewPlaying; Button("PreviewPlayButton").Content = previewPlaying ? "暂停预览" : "播放预览";
            });
            SetupVideo("ArtworkVideo", "EmptyPreview"); SetupVideo("LibraryVideo", "LibraryEmpty");
            refreshTimer.Tick += async delegate { if (!busy && !refreshing && !sliderEditing && !pendingReveal.HasValue) await RefreshAll(false); };
            window.Loaded += async delegate
            {
                RoundClip(Find<FrameworkElement>("ArtworkViewport"), 22); RoundClip(Find<FrameworkElement>("LibraryViewport"), 22);
                UpdateShade(); UpdatePresets(); ShowPage(0); await RefreshAll(true); refreshTimer.Start();
                // Opened behind another window: rest until it is brought forward.
                if (!testMode && !window.IsActive) { ambience.SetActive(false); Find<MediaElement>("ArtworkVideo").Pause(); }
            };
            window.Deactivated += delegate { ambience.SetActive(false); Find<MediaElement>("ArtworkVideo").Pause(); Find<MediaElement>("LibraryVideo").Pause(); };
            window.Activated += delegate { ambience.SetActive(true); if (page == 0 && previewPlaying) Find<MediaElement>("ArtworkVideo").Play(); if (page == 1 && selected != null && selected.MediaType == "video") Find<MediaElement>("LibraryVideo").Play(); };
            window.KeyDown += async delegate(object sender, KeyEventArgs e)
            {
                if (e.Key == Key.F5) { e.Handled = true; if (!busy) await RefreshAll(true); }
                else if (e.Key == Key.O && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; if (!busy) await AddMedia(); }
            };
            window.Closing += delegate(object sender, System.ComponentModel.CancelEventArgs e)
            {
                if (busy || pendingReveal.HasValue || wallpaperLink.IsMutating) { e.Cancel = true; closingRequested = true; Label("StatusText").Text = "正在完成当前操作，完成后关闭管理器。"; if (pendingReveal.HasValue) { revealTimer.Stop(); revealTimer.Start(); } }
            };
        }
        private ThemeInfo Sample(ThemeInfo theme)
        {
            if (theme == null || sampleArt.Count == 0) return theme;
            int slot;
            if (!sampleSlots.TryGetValue(theme.Id, out slot)) { slot = sampleSlots.Count; sampleSlots[theme.Id] = slot; }
            theme.MediaPath = sampleArt[slot % sampleArt.Count]; theme.MediaType = "image";
            theme.Name = SampleNames[slot % SampleNames.Length] + (slot >= SampleNames.Length ? " " + (slot / SampleNames.Length + 1) : "");
            return theme;
        }
        private static void RoundClip(FrameworkElement element, double radius)
        {
            if (element == null) return;
            SizeChangedEventHandler update = delegate { element.Clip = new RectangleGeometry(new Rect(0, 0, element.ActualWidth, element.ActualHeight), radius, radius); };
            element.SizeChanged += update; update(element, null);
        }
        private static void Mark(Button button, bool chosen) { button.Tag = chosen ? "on" : null; }
        private void Click(string name, Action action) { Button(name).Click += delegate { try { action(); } catch (Exception ex) { ReportError(ex); } }; }
        private void AsyncClick(string name, Func<Task> action) { Button(name).Click += async delegate { uiActionActive = true; try { await action(); } catch (Exception ex) { ReportError(ex); } finally { uiActionActive = false; } }; }
        private void SetupVideo(string name, string emptyName)
        {
            var media = Find<MediaElement>(name);
            media.MediaEnded += delegate { media.Position = TimeSpan.Zero; if (window.IsActive && ((name == "ArtworkVideo" && page == 0 && previewPlaying) || (name == "LibraryVideo" && page == 1))) media.Play(); };
            media.MediaOpened += async delegate
            {
                bool home = name == "ArtworkVideo";
                if (media.NaturalVideoWidth > 0) Find<Border>(home ? "ArtworkViewport" : "LibraryViewport").Height = 1000.0 * media.NaturalVideoHeight / media.NaturalVideoWidth;
                if (name == "ArtworkVideo" && media.NaturalDuration.HasTimeSpan)
                    Label("MediaDetails").Text = "类型：MP4 / 视频\n时长：" + media.NaturalDuration.TimeSpan.TotalSeconds.ToString("0.#", CultureInfo.InvariantCulture) + " 秒\n画面：" + media.NaturalVideoWidth + " × " + media.NaturalVideoHeight + "\n播放：静音循环";
                // Windows had no thumbnail to take colours from: use a frame of the playing video.
                string source = media.Source == null ? "" : media.Source.LocalPath;
                await Task.Delay(1500);
                if (disposed || media.Source == null || media.Source.LocalPath != source || (home ? activeSeedPath : selectedSeedPath) != source || (home ? activeSeeds : selectedSeeds) != null) return;
                Color[] sampled;
                try { sampled = WallpaperColors.Extract(WallpaperColors.Snapshot(media, 64)); }
                catch (Exception) { return; } // Lighting is decorative; the theme's own colours remain.
                if (sampled == null) return;
                if (home) activeSeeds = sampled; else selectedSeeds = sampled;
                UpdateAmbience();
            };
            media.MediaFailed += delegate(object sender, ExceptionRoutedEventArgs e)
            {
                media.Visibility = Visibility.Collapsed; var message = Label(emptyName); message.Visibility = Visibility.Visible;
                message.Text = "此格式暂时无法在管理器中预览\n仍可尝试应用到 Codex";
                if (name == "ArtworkVideo") Button("PreviewPlayButton").Visibility = Visibility.Collapsed;
            };
        }
        private void ShowPage(int index)
        {
            bool moved = page != index && window.IsLoaded;
            page = index;
            Find<Grid>("HomePage").Visibility = index == 0 ? Visibility.Visible : Visibility.Collapsed;
            Find<Grid>("LibraryPage").Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
            Find<ScrollViewer>("SettingsPage").Visibility = index == 2 ? Visibility.Visible : Visibility.Collapsed;
            string[] titles = { "当前背景", "主题收藏", "工作室" };
            string[] subtitles = { "一张画面，一点个性。把工作空间变成你的。", "收藏不同的风景，挑一张作为今天的背景。", "配色、联动、启动与诊断，都在这里。" };
            Label("PageTitle").Text = titles[index]; Label("PageSubtitle").Text = subtitles[index];
            Label("PageEyebrow").Text = new[] { "CANVAS", "COLLECTION", "STUDIO" }[index];
            for (int i = 0; i < 3; i++) Mark(Button(new[] { "NavHome", "NavLibrary", "NavSettings" }[i]), i == index);
            ambience.MoveNav(index * 46, moved);
            Button("ApplyButton").Content = index == 1 ? "应用所选主题" : index == 2 ? "重新应用背景" : "打开主题版 Codex";
            Button("ApplyButton").IsEnabled = !busy && (index != 1 || selected != null);
            if (index == 1) { Find<MediaElement>("ArtworkVideo").Pause(); if (selected != null && selected.MediaType == "video") Find<MediaElement>("LibraryVideo").Play(); }
            else { Find<MediaElement>("LibraryVideo").Pause(); if (index == 0 && previewPlaying) Find<MediaElement>("ArtworkVideo").Play(); else Find<MediaElement>("ArtworkVideo").Pause(); }
            ambience.Rise(Find<FrameworkElement>("PageHeading"), TimeSpan.Zero);
            ambience.Enter(Find<FrameworkElement>(new[] { "HomePage", "LibraryPage", "SettingsPage" }[index]));
            UpdateAmbience();
        }
        /// <summary>The window lights itself from the wallpaper in use, or on the collection page from the one being previewed.</summary>
        private void UpdateAmbience()
        {
            UiPalette.SetWallpaperSeeds(window, page == 1 && selected != null && selectedSeeds != null ? selectedSeeds : activeSeeds);
        }
        private async void LoadSeeds(ThemeInfo theme, bool home)
        {
            string source = theme == null ? "" : theme.MediaPath;
            if ((home ? activeSeedPath : selectedSeedPath) == source) return;
            if (home) { activeSeedPath = source; activeSeeds = null; } else { selectedSeedPath = source; selectedSeeds = null; }
            if (source.Length > 0)
            {
                var preview = await Thumbnails.Get(source, theme.MediaType == "video");
                if (disposed || (home ? activeSeedPath : selectedSeedPath) != source) return;
                if (home) activeSeeds = preview.Seeds; else selectedSeeds = preview.Seeds;
            }
            UpdateAmbience();
        }
        private async Task RefreshAll(bool includeLibrary)
        {
            if (refreshing || disposed) return; refreshing = true;
            try
            {
                var status = await Task.Run(delegate { return EngineBridge.Call("Status"); });
                ApplyStatus(status);
                if (includeLibrary || (int)Json.Number(status, "savedCount") != themes.Count)
                {
                    var result = await Task.Run(delegate { return EngineBridge.Call("ListThemes"); });
                    var entries = Json.Get(result, "themes") as System.Collections.IEnumerable;
                    themes = entries == null ? new List<ThemeInfo>() : entries.Cast<object>().Select(x => Sample(ThemeInfo.From(Json.Map(x)))).ToList();
                    RenderLibrary();
                }
                if (!busy) Label("StatusText").Text = paused ? "背景已暂停 · 点击「继续显示」恢复。" : "已读取当前配置 · 操作会自动保存。";
            }
            catch (Exception ex) { if (includeLibrary) ReportError(ex); else { Label("StatusText").Text = "状态读取暂不可用，点击刷新重试。"; } }
            finally { refreshing = false; }
        }
        private void ApplyStatus(Dictionary<string, object> status)
        {
            loading = true;
            try
            {
                var data = Json.Map(Json.Get(status, "active")); active = data.Count == 0 ? null : Sample(ThemeInfo.From(data));
                UpdateSelectionActions();
                if (UiPalette.Mode == "follow-theme") UiPalette.ApplyTheme(window, Json.Map(Json.Get(data, "colors")));
                LoadSeeds(active, true);
                paused = Json.Bool(status, "paused"); var running = Json.Map(Json.Get(status, "running"));
                bool connected = Json.Bool(running, "portListening") && Json.Bool(running, "injectorAlive");
                Label("ConnectionLabel").Text = paused ? "背景已暂停" : connected ? "主题引擎在线" : "等待连接 Codex";
                Find<System.Windows.Shapes.Ellipse>("ConnectionDot").Fill = paused ? UiPalette.Subtle : connected ? Brush("#3DD68C") : Brush("#F5B84B");
                Label("EngineLabel").Text = "引擎 " + Json.Text(status, "engineVersion", "—") + " · 本机运行";
                Button("PauseSkinButton").Content = paused ? "恢复 Codex 背景" : "暂停 Codex 背景";
                Find<CheckBox>("AutoStartCheck").IsChecked = Json.Bool(status, "autoStart");
                Label("ActiveThemeName").Text = active == null ? "尚未设置背景" : active.Name;
                Label("MediaFileName").Text = active == null ? "导入图片或视频开始使用" : Path.GetFileName(active.MediaPath);
                if (active != null && !sliderEditing && !pendingReveal.HasValue)
                {
                    double reveal = Json.Get(data, "sourceTransparency") == null ? active.Reveal : Json.Number(data, "sourceTransparency", active.Reveal);
                    Reveal.Value = Math.Max(0, Math.Min(100, reveal));
                }
                Reveal.IsEnabled = active != null && !busy;
                Label("MediaTypeLabel").Text = active == null ? "无背景" : active.MediaType == "video" ? "视频 · 静音" : "图片";
                if (active == null || active.MediaPath != activePreviewPath)
                {
                    activePreviewPath = active == null ? "" : active.MediaPath;
                    LoadPreview(active, "ArtworkImage", "ArtworkVideo", "EmptyPreview");
                    previewPlaying = active != null && active.MediaType == "video";
                    Button("PreviewPlayButton").Visibility = previewPlaying ? Visibility.Visible : Visibility.Collapsed;
                    Button("PreviewPlayButton").Content = "暂停预览";
                    if (active != null)
                    {
                        long size = File.Exists(active.MediaPath) ? new FileInfo(active.MediaPath).Length : 0;
                        Label("MediaDetails").Text = "类型：" + (active.MediaType == "video" ? "视频" : "图片") + "\n大小：" + (size / 1048576.0).ToString("0.0", CultureInfo.InvariantCulture) + " MB\n源文件保留在本机";
                    }
                }
            }
            finally { loading = false; }
        }
        private void RenderLibrary()
        {
            string query = Find<TextBox>("SearchBox").Text.Trim(); string preserve = selected == null ? "" : selected.Directory;
            var filtered = themes.Where(t => query.Length == 0 || t.Name.IndexOf(query, StringComparison.CurrentCultureIgnoreCase) >= 0).ToList();
            var list = Find<ListBox>("ThemeList"); list.Items.Clear();
            foreach (ThemeInfo theme in filtered)
            {
                var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
                var thumb = new Border { Width = 72, Height = 44, Background = Brush("#0A0B0E"), HorizontalAlignment = HorizontalAlignment.Left, Clip = new RectangleGeometry(new Rect(0, 0, 72, 44), 9, 9), Child = Icon(theme.MediaType == "video" ? "\uE768" : "\uE91B") };
                FillThumbnail(thumb, theme);
                grid.Children.Add(thumb); var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(text, 1);
                text.Children.Add(new TextBlock { Text = theme.Name, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, FontWeight = FontWeights.SemiBold, FontSize = 14 });
                bool current = active != null && String.Equals(theme.Id, active.Id, StringComparison.Ordinal);
                var meta = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
                meta.Children.Add(new TextBlock { Text = theme.MediaType == "video" ? "视频" : "图片", FontSize = 12, Foreground = UiPalette.Muted, VerticalAlignment = VerticalAlignment.Center });
                if (current) meta.Children.Add(new Border { Background = UiPalette.AccentGradient, CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(8, 0, 0, 0), Child = new TextBlock { Text = "使用中", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = UiPalette.OnAccent } });
                text.Children.Add(meta);
                grid.Children.Add(text); var row = new ListBoxItem { Content = grid, Tag = theme }; list.Items.Add(row); if (theme.Directory == preserve) list.SelectedItem = row;
            }
            Label("LibraryCount").Text = "已收藏 " + themes.Count + " 个主题";
            if (selected == null) ShowSelected();
        }
        private async void FillThumbnail(Border frame, ThemeInfo theme)
        {
            var pending = Thumbnails.Get(theme.MediaPath, theme.MediaType == "video");
            bool cached = pending.IsCompleted;
            var preview = await pending;
            if (disposed || preview.Image == null) return;
            var picture = new Image { Source = preview.Image, Stretch = Stretch.UniformToFill };
            frame.Child = picture;
            if (!cached) ambience.Reveal(picture);
        }
        private TextBlock Icon(string text) { return new TextBlock { Text = text, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 15, Foreground = Brush("#C8CCD6"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }; }
        private void ShowSelected()
        {
            Label("SelectedThemeName").Text = selected == null ? "尚未选择主题" : selected.Name;
            Label("SelectedThemeInfo").Text = selected == null ? "支持图片与视频主题" : (selected.MediaType == "video" ? "视频主题" : "图片主题") + " · " + Path.GetFileName(selected.MediaPath);
            UpdateSelectionActions();
            if (page == 1) Button("ApplyButton").IsEnabled = selected != null && !busy;
            LoadPreview(selected, "LibraryImage", "LibraryVideo", "LibraryEmpty");
            LoadSeeds(selected, false);
        }
        private void LoadPreview(ThemeInfo theme, string imageName, string videoName, string emptyName)
        {
            var image = Find<Image>(imageName); var video = Find<MediaElement>(videoName); var empty = Label(emptyName);
            video.Stop(); video.Source = null; video.Visibility = Visibility.Collapsed; image.Source = null; image.Visibility = Visibility.Collapsed;
            empty.Text = theme == null ? "选择图片、视频或已保存主题进行预览" : "预览载入中…"; empty.Visibility = Visibility.Visible;
            var shape = Find<Border>(imageName == "ArtworkImage" ? "ArtworkViewport" : "LibraryViewport");
            if (theme == null || !File.Exists(theme.MediaPath)) { shape.Height = 562; return; }
            try
            {
                if (theme.MediaType == "video") { video.Source = new Uri(theme.MediaPath); video.Visibility = Visibility.Visible; video.Play(); }
                else { var bitmap = Bitmap(theme.MediaPath, 1600); image.Source = bitmap; image.Visibility = Visibility.Visible; shape.Height = 1000.0 * bitmap.PixelHeight / bitmap.PixelWidth; ambience.Reveal(image); }
                empty.Visibility = Visibility.Collapsed;
            }
            catch { empty.Text = "无法读取预览，原文件未改动。"; }
        }
        private static BitmapImage Bitmap(string path, int width)
        {
            var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.DecodePixelWidth = width; image.UriSource = new Uri(path); image.EndInit(); image.Freeze(); return image;
        }
        private void UpdateShade()
        {
            bool simulated = Find<CheckBox>("SimulateOpacity").IsChecked == true;
            Find<Border>("PreviewShade").Visibility = simulated ? Visibility.Visible : Visibility.Collapsed; Find<Border>("PreviewShade").Opacity = 1 - Reveal.Value / 100;
            Label("PreviewNote").Text = simulated ? "应用效果 · " + Math.Round(Reveal.Value) + "% 透出度" : "原始画面 · 完整比例";
            foreach (string name in new[] { "PreviewOriginalButton", "PreviewEffectButton" }) Mark(Button(name), simulated == (name == "PreviewEffectButton"));
        }
        private void UpdatePresets()
        {
            foreach (int value in new[] { 60, 75, 90 }) Mark(Button("Reveal" + value), Math.Abs(Reveal.Value - value) < 0.5);
        }
        private void QueueReveal(int value) { Reveal.Value = value; pendingReveal = value; revealTimer.Stop(); revealTimer.Start(); }
        private async Task ApplySelected() { if (selected != null) await Execute("ApplyTheme", "正在应用「" + selected.Name + "」…", "-ThemeId", selected.Id); }
        private async Task AddMedia()
        {
            var dialog = new OpenFileDialog { Title = "选择背景图片或视频", Filter = "图片和视频|*.png;*.jpg;*.jpeg;*.webp;*.mp4;*.webm|图片|*.png;*.jpg;*.jpeg;*.webp|视频|*.mp4;*.webm", CheckFileExists = true };
            if (dialog.ShowDialog(window) == true) await Execute("SetWallpaper", "正在导入并应用背景…", "-Path", dialog.FileName);
        }
        private async Task ImportZip()
        {
            var dialog = new OpenFileDialog { Title = "导入 DreamSkin 主题包", Filter = "主题 ZIP|*.zip", CheckFileExists = true };
            if (dialog.ShowDialog(window) == true) { await Execute("ImportTheme", "正在校验并导入主题包…", "-Path", dialog.FileName); ShowPage(1); }
        }
        private async Task SaveTheme()
        {
            string name = AskName("加入收藏", active == null ? "我的主题" : active.Name, "保存主题");
            if (name != null) await Execute("SaveTheme", "正在保存当前主题…", "-Name", name);
        }
        private void UpdateSelectionActions()
        {
            bool editable = selected != null && !busy;
            bool current = selected != null && active != null && String.Equals(selected.Id, active.Id, StringComparison.Ordinal);
            Button("ApplySelectedButton").IsEnabled = editable;
            Button("OpenSelectedButton").IsEnabled = editable;
            Button("RenameSelectedButton").IsEnabled = editable;
            Button("RecycleSelectedButton").IsEnabled = editable && !current;
            Button("RecycleSelectedButton").ToolTip = current ? "请先切换到其他主题。" : "可从 Windows 回收站恢复。";
        }
        private async Task RenameSelected()
        {
            var theme = selected;
            if (theme == null) return;
            string name = AskName("重命名主题", theme.Name, "保存名称");
            if (name != null && !String.Equals(name, theme.Name, StringComparison.Ordinal))
                await Execute("RenameTheme", "正在保存新名称…", "-ThemeId", theme.Id, "-Name", name);
        }
        private async Task RecycleSelected()
        {
            var theme = selected;
            if (theme == null || (active != null && String.Equals(theme.Id, active.Id, StringComparison.Ordinal))) return;
            string message = "把「" + theme.Name + "」移到 Windows 回收站？\n可以从回收站恢复。";
            if (MessageBox.Show(window, message, "移到回收站", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
            // A playing collection preview can lock the file being recycled.
            var preview = Find<MediaElement>("LibraryVideo");
            preview.Close();
            preview.Source = null;
            await Execute("RecycleTheme", "正在将主题移到回收站…", "-ThemeId", theme.Id);
            if (selected != null && String.Equals(selected.Id, theme.Id, StringComparison.Ordinal)) ShowSelected();
        }
        private string AskName(string title, string initialName, string actionText)
        {
            var dialog = new Window { Owner = window, Title = title, Width = 440, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = UiPalette.Paper, Foreground = UiPalette.Ink, FontFamily = window.FontFamily, FontSize = 14, ShowInTaskbar = false };
            dialog.Resources.MergedDictionaries.Add(window.Resources);
            var box = new TextBox { Text = initialName, MaxLength = 80, Margin = new Thickness(0, 10, 0, 18) };
            var save = new Button { Content = actionText, Style = (Style)window.FindResource("Primary"), Padding = new Thickness(18, 8, 18, 8), IsDefault = true };
            var cancel = new Button { Content = "取消", IsCancel = true, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(16, 8, 16, 8) };
            var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            actions.Children.Add(cancel); actions.Children.Add(save);
            var panel = new StackPanel { Margin = new Thickness(24) };
            panel.Children.Add(new Label { Content = "主题名称", Target = box, Foreground = UiPalette.Muted, Padding = new Thickness(0) });
            panel.Children.Add(box); panel.Children.Add(actions); dialog.Content = panel;
            box.TextChanged += delegate { save.IsEnabled = box.Text.Trim().Length > 0; };
            save.Click += delegate { dialog.DialogResult = true; };
            dialog.Loaded += delegate { box.Focus(); box.SelectAll(); };
            return dialog.ShowDialog() == true ? box.Text.Trim() : null;
        }
        private async Task EditColors()
        {
            var dialog = new ThemeColorDialog(window); dialog.ShowDialog();
            if (dialog.CodexChanged) { AddLog("Codex 主题配色已保存，视频与透出度保持不变。"); await RefreshAll(false); }
        }
        private async Task Diagnose()
        {
            await Execute("Diagnostics", "正在检查连接与主题文件…");
        }
        private async Task Execute(string action, string message, params string[] args)
        {
            if (busy) return; SetBusy(true, message); AddLog(message);
            bool yieldToCodex = action == "OpenCodex" || action == "Apply" || action == "ApplyTheme" || action == "Resume" || action == "SetWallpaper";
            bool openingInProgress = false;
            WindowState previousWindowState = window.WindowState;
            try
            {
                Exception failure = null;
                try
                {
                    var result = await Task.Run(delegate { return EngineBridge.Call(action, args); });
                    if (action == "OpenCodex")
                    {
                        openingInProgress = Json.Bool(result, "opening");
                        // A concurrent opener's acknowledgement is not evidence
                        // that its window is ready. Leave this manager usable.
                        if (!openingInProgress && !testMode && !disposed && !closingRequested)
                            window.WindowState = WindowState.Minimized;
                    }
                    if (action == "SetWallpaper" && Json.Bool(result, "requiresApply"))
                    {
                        Label("StatusText").Text = "背景已导入，正在应用到 Codex…";
                        // Apply starts its own backend and receives the same
                        // foreground grant as an explicit Apply button click.
                        await Task.Run(delegate { return EngineBridge.Call("Apply"); });
                    }
                    if (action == "Diagnostics") { Find<TextBox>("DiagnosticsText").Text = FormatDiagnostics(result); Find<TextBox>("HistoryLogText").Text = FormatHistoryLogs(result); }
                    string success = openingInProgress ? "主题版 Codex 正在打开，请稍候。" : action == "ImportTheme" ? "主题已导入主题库，选中后点击「应用所选主题」。" : action == "SetReveal" ? "背景可见度已保存为 " + args.Last() + "%。" : action == "Pause" ? "背景已暂停。" : action == "Restore" ? "官方外观恢复操作已完成。" : action == "SetAutoStart" ? "登录启动设置已保存。" : action == "Diagnostics" ? "诊断已完成。" : "操作已完成，配置已保存。";
                    if (action == "RenameTheme") success = "已重命名为「" + Json.Text(result, "name") + "」。";
                    if (action == "RecycleTheme") success = "主题已移到 Windows 回收站。";
                    AddLog(success); while (refreshing) await Task.Delay(100); await RefreshAll(action != "SetReveal"); Label("StatusText").Text = success;
                }
                catch (Exception ex) { failure = ex; }
                if (failure != null)
                {
                    if (yieldToCodex && !testMode && !disposed && !closingRequested)
                    {
                        window.WindowState = previousWindowState == WindowState.Minimized ? WindowState.Normal : previousWindowState;
                        window.Show(); window.Activate();
                    }
                    while (refreshing) await Task.Delay(100); await RefreshAll(false); ReportError(failure);
                }
            }
            finally { SetBusy(false, null); if (closingRequested && !pendingReveal.HasValue) window.Close(); }
        }
        private void SetBusy(bool value, string message)
        {
            busy = value; Find<ProgressBar>("BusyProgress").Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            foreach (var pair in buttons) pair.Value.IsEnabled = !value;
            UpdateSelectionActions();
            Button("ApplyButton").IsEnabled = !value && (page != 1 || selected != null);
            Reveal.IsEnabled = !value && active != null; Find<CheckBox>("AutoStartCheck").IsEnabled = !value;
            if (message != null) Label("StatusText").Text = message;
        }
        private void AddLog(string text) { log.Insert(0, DateTime.Now.ToString("HH:mm:ss") + "  " + text + Environment.NewLine); if (log.Length > 8000) log.Length = 8000; Find<TextBox>("ActivityLog").Text = log.ToString(); }
        private string FormatDiagnostics(Dictionary<string, object> result)
        {
            var snapshot = Json.Map(Json.Get(result, "status")); var current = Json.Map(Json.Get(snapshot, "active")); var running = Json.Map(Json.Get(snapshot, "running"));
            var text = new StringBuilder();
            text.AppendLine("检查时间：" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            text.AppendLine("DreamSkin 引擎：" + Json.Text(snapshot, "engineVersion"));
            text.AppendLine("当前主题：" + (sampleArt.Count > 0 && active != null ? active.Name : Json.Text(current, "name", "未设置")));
            text.AppendLine("媒体类型：" + (Json.Text(current, "mediaType") == "video" ? "视频" : "图片"));
            text.AppendLine("媒体文件：" + (File.Exists(Json.Text(current, "mediaPath")) ? "存在" : "未找到"));
            text.AppendLine("背景可见度：" + Json.Number(current, "reveal") + "%");
            text.AppendLine("背景暂停：" + (Json.Bool(snapshot, "paused") ? "是" : "否"));
            text.AppendLine("本地连接：" + (Json.Bool(running, "portListening") ? "可连接" : "未连接"));
            text.AppendLine("壁纸进程：" + (Json.Bool(running, "injectorAlive") ? "运行中" : "未运行"));
            text.AppendLine("已保存主题：" + Json.Number(snapshot, "savedCount"));
            text.AppendLine("\n此检查确认文件与连接；实际画面请以 Codex 为准。");
            return text.ToString();
        }
        private string FormatHistoryLogs(Dictionary<string, object> result)
        {
            var text = new StringBuilder("以下是引擎日志，不代表本次检查失败。\n\n");
            var logs = Json.Get(result, "logs") as System.Collections.IEnumerable;
            if (logs != null) foreach (object entry in logs) { var record = Json.Map(entry); string tail = Json.Text(record, "tail"); if (tail.Length == 0) continue; text.AppendLine("── " + Json.Text(record, "name") + " ──"); string path = Json.Text(record, "path"); if (File.Exists(path)) text.AppendLine("文件最后更新：" + File.GetLastWriteTime(path).ToString("yyyy-MM-dd HH:mm:ss")); var lines = tail.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries); text.AppendLine(String.Join(Environment.NewLine, lines.Skip(Math.Max(0, lines.Length - 6)).ToArray())); text.AppendLine(); }
            return text.ToString();
        }
        internal async Task<Dictionary<string, object>> RunReadOnlySelfTest(string folder)
        {
            refreshTimer.Stop();
            var deadline = DateTime.UtcNow.AddSeconds(25);
            while ((refreshing || active == null) && DateTime.UtcNow < deadline) await Task.Delay(150);
            if (active == null) throw new InvalidOperationException("Initial live status did not load.");
            if (themes.Count < 1) throw new InvalidOperationException("Theme library did not deserialize live entries.");
            int libraryCount = themes.Count; string activePath = active.MediaPath; double reveal = Reveal.Value;
            await wallpaperLink.LoadStatus(); if (!wallpaperLink.StatusLoaded) throw new InvalidOperationException("Wallpaper Engine configuration did not load.");
            ShowPage(0); await Task.Delay(1400);
            if (window.FindName("MotionField") != null) throw new InvalidOperationException("Dense contour field remains in the layout.");
            if (!(window.FindName("ArtworkFrame") is Viewport3D)) throw new InvalidOperationException("The tilting preview stage is missing.");
            var layout = new Dictionary<string, object>();
            // Motion: the aurora drifts on its own, and hover/press storyboards must run without errors.
            bool auroraMoved = false, effectsExercised = false;
            if (ambience.Rich)
            {
                var drift = (TranslateTransform)Find<FrameworkElement>("Blob1").RenderTransform; double before = drift.X; await Task.Delay(400);
                auroraMoved = Math.Abs(drift.X - before) > 0.01;
                if (!auroraMoved) throw new InvalidOperationException("The ambient lights are not moving.");
                var hoverTargets = new List<UIElement> { Button("ApplyButton"), Button("ChangeMediaButton"), Button("NavLibrary"), Button("Reveal60") };
                var track = Reveal.Template.FindName("PART_Track", Reveal) as System.Windows.Controls.Primitives.Track;
                if (track != null && track.Thumb != null) hoverTargets.Add(track.Thumb);
                foreach (UIElement target in hoverTargets)
                {
                    target.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, 0) { RoutedEvent = Mouse.MouseEnterEvent });
                    target.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = UIElement.PreviewMouseLeftButtonDownEvent });
                }
                ambience.Pose(new Point(window.ActualWidth - 330, 330), 0.85, -0.7); await Task.Delay(330);
                Capture(Path.Combine(folder, "effects.png"));
                foreach (UIElement target in hoverTargets)
                {
                    target.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = UIElement.PreviewMouseLeftButtonUpEvent });
                    target.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, 0) { RoutedEvent = Mouse.MouseLeaveEvent });
                }
                ambience.Unpose(); await Task.Delay(450);
                effectsExercised = true;
                if (sampleArt.Count > 0)
                {
                    // One circle of the pointer around the stage, frame by frame.
                    string frames = Path.Combine(folder, "tilt"); Directory.CreateDirectory(frames);
                    var stage = Find<FrameworkElement>("HomeStage");
                    Point corner = stage.TransformToAncestor((Visual)window.Content).Transform(new Point());
                    for (int i = 0; i < 30; i++)
                    {
                        double turn = i / 30.0 * Math.PI * 2, x = Math.Cos(turn) * 0.82, y = Math.Sin(turn) * 0.78;
                        ambience.Pose(new Point(corner.X + (x + 1) / 2 * stage.ActualWidth, corner.Y + (y + 1) / 2 * stage.ActualHeight), x, y);
                        await Task.Delay(40);
                        Capture(Path.Combine(frames, i.ToString("00") + ".png"));
                    }
                    ambience.Unpose(); await Task.Delay(450);
                }
            }
            if (window.FindName("BannerDream") != null) throw new InvalidOperationException("Oversized banner remains in the layout.");
            if (!"on".Equals(Button("NavHome").Tag)) throw new InvalidOperationException("Navigation selection state is missing.");
            var player = Find<MediaElement>("ArtworkVideo"); bool videoMetadata = false; bool playheadAdvanced = false;
            if (active.MediaType == "video")
            {
                deadline = DateTime.UtcNow.AddSeconds(8);
                while (!player.NaturalDuration.HasTimeSpan && DateTime.UtcNow < deadline) await Task.Delay(100);
                videoMetadata = player.NaturalDuration.HasTimeSpan && player.NaturalVideoWidth > 0;
                player.Position = TimeSpan.Zero; player.Play(); await Task.Delay(900); playheadAdvanced = player.Position.TotalMilliseconds > 50; player.Pause();
            }
            Capture(Path.Combine(folder, "home.png"));
            layout["home"] = Bounds("NavHome", "NavLibrary", "NavSettings", "AddMediaButton", "ApplyButton", "RefreshButton", "HomeStage", "ChangeMediaButton", "SaveThemeButton", "PauseSkinButton", "ShowLibraryButton", "RevealSlider", "Reveal60", "Reveal90", "PreviewOriginalButton", "PreviewEffectButton", "ColorsButton", "ConnectionLabel");
            Button("PreviewEffectButton").RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            if (Find<Border>("PreviewShade").Visibility != Visibility.Visible || Math.Abs(Find<Border>("PreviewShade").Opacity - (1 - reveal / 100)) > 0.001) throw new InvalidOperationException("Preview effect mode did not match the reveal setting.");
            Button("PreviewOriginalButton").RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            if (Find<Border>("PreviewShade").Visibility != Visibility.Collapsed) throw new InvalidOperationException("Original preview did not clear its shade.");
            var controlNames = new[] { "ApplyButton", "ChangeMediaButton", "PauseSkinButton", "SaveThemeButton", "RevealSlider", "Reveal75" };
            var bounds = new List<object>();
            foreach (string name in controlNames)
            {
                var control = Find<FrameworkElement>(name); Point point = control.TransformToAncestor((Visual)window.Content).Transform(new Point());
                bool inside = control.ActualWidth > 0 && control.ActualHeight > 0 && point.X >= 0 && point.Y >= 0 && point.X + control.ActualWidth <= window.ActualWidth + 2 && point.Y + control.ActualHeight <= window.ActualHeight + 2;
                if (!inside) throw new InvalidOperationException("Control bounds overflow: " + name);
                bounds.Add(new { name = name, x = point.X, y = point.Y, width = control.ActualWidth, height = control.ActualHeight });
            }
            // Search for the start of a name that is known to exist, whatever this library holds.
            string sought = themes[0].Name.Substring(0, Math.Min(2, themes[0].Name.Length));
            ShowPage(1); Find<TextBox>("SearchBox").Text = sought; await Task.Delay(200);
            var list = Find<ListBox>("ThemeList"); int filteredCount = list.Items.Count;
            if (filteredCount < 1) throw new InvalidOperationException("Search did not find a known live theme.");
            list.SelectedIndex = 0; await Task.Delay(350);
            if (selected == null || !Button("ApplySelectedButton").IsEnabled) throw new InvalidOperationException("Selected theme preview did not enable Apply.");
            Button("ClearSearchButton").RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)); await Task.Delay(300);
            if (list.Items.Count != libraryCount) throw new InvalidOperationException("Clear search did not restore the full collection.");
            var rows = list.Items.OfType<ListBoxItem>().ToList();
            var currentRow = rows.FirstOrDefault(item => ((ThemeInfo)item.Tag).Id == active.Id);
            var otherRow = rows.FirstOrDefault(item => ((ThemeInfo)item.Tag).Id != active.Id);
            if (currentRow != null)
            {
                list.SelectedItem = currentRow;
                if (!Button("RenameSelectedButton").IsEnabled || Button("RecycleSelectedButton").IsEnabled)
                    throw new InvalidOperationException("Current theme cannot be safely managed.");
            }
            if (otherRow != null)
            {
                list.SelectedItem = otherRow;
                if (!Button("RenameSelectedButton").IsEnabled || !Button("RecycleSelectedButton").IsEnabled)
                    throw new InvalidOperationException("Inactive theme management actions are unavailable.");
            }
            var firstRow = list.Items.OfType<ListBoxItem>().First();
            firstRow.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, 0) { RoutedEvent = Mouse.MouseEnterEvent });
            firstRow.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, 0) { RoutedEvent = Mouse.MouseLeaveEvent });
            await Task.Delay(2600); // thumbnails, the selected theme's colours, and the colour glide
            string libraryAccent = UiPalette.Hex;
            Capture(Path.Combine(folder, "library.png"));
            layout["library"] = Bounds("SearchBox", "ThemeList", "ImportZipButton", "OpenLibraryButton", "LibraryStage", "ApplySelectedButton", "RenameSelectedButton", "RecycleSelectedButton", "OpenSelectedButton", "ApplyButton");
            if (sampleArt.Count > 0)
            {
                // The same page lit by three other pictures.
                for (int shot = 0; shot < 3 && shot + 1 < list.Items.Count; shot++)
                {
                    list.SelectedIndex = shot + 1; await Task.Delay(1900);
                    Capture(Path.Combine(folder, "palette-" + shot + ".png"));
                }
            }
            ShowPage(2); await Task.Delay(150); if (ambience.Rich) Capture(Path.Combine(folder, "entrance.png"));
            ShowPage(2); await Task.Delay(1500); await wallpaperLink.LoadStatus(); wallpaperLink.SelectMonitorForPreview("Monitor1"); await Diagnose(); Capture(Path.Combine(folder, "settings.png"));
            layout["settings"] = Bounds("SettingsColorsButton", "AutoStartCheck", "OpenEngineFolderButton", "RestoreButton", "WallpaperLinkHost", "DiagnoseButton", "DiagnosticsText", "ApplyButton");
            string diagnosis = Find<TextBox>("DiagnosticsText").Text;
            if (!diagnosis.Contains("当前主题")) throw new InvalidOperationException("Readable diagnostics did not load.");
            window.Width = 1080; window.Height = 730; ShowPage(0); await Task.Delay(1500); Capture(Path.Combine(folder, "compact.png"));
            foreach (string name in controlNames)
            {
                var control = Find<FrameworkElement>(name); Point point = control.TransformToAncestor((Visual)window.Content).Transform(new Point());
                if (point.X < 0 || point.Y < 0 || point.X + control.ActualWidth > window.ActualWidth + 2 || point.Y + control.ActualHeight > window.ActualHeight + 2) throw new InvalidOperationException("Compact control bounds overflow: " + name);
            }
            ShowPage(2); await Task.Delay(1200); Capture(Path.Combine(folder, "compact-settings.png"));
            string initialUiHex = UiPalette.Hex;
            string followAccent = UiPalette.Hex;
            UiPalette.Apply(window, "#35303C"); ShowPage(0); await Task.Delay(1500); Capture(Path.Combine(folder, "dark-ui-palette.png"));
            if (UiPalette.ContrastRatio < 4.5 || UiPalette.InkColor.R < 200) throw new InvalidOperationException("Dark UI palette did not choose legible light text.");
            UiPalette.Load(window, EngineBridge.StateRoot); if (sampleArt.Count > 0) UiPalette.FollowForThisSession(window); await RefreshAll(false);
            var colorDialog = new ThemeColorDialog(window);
            colorDialog.WindowStartupLocation = WindowStartupLocation.Manual; colorDialog.Left = -20000; colorDialog.Top = -20000; colorDialog.ShowActivated = false; colorDialog.ShowInTaskbar = false;
            colorDialog.Show(); deadline = DateTime.UtcNow.AddSeconds(25);
            while (!colorDialog.ReadOnlyDataReady && DateTime.UtcNow < deadline) await Task.Delay(100);
            if (!colorDialog.ReadOnlyDataReady) { colorDialog.Close(); throw new InvalidOperationException("Current theme colors did not load in the color dialog."); }
            CaptureVisual((FrameworkElement)colorDialog.Content, Path.Combine(folder, "color-dialog.png")); colorDialog.Close();

            if (active.MediaPath != activePath || Math.Abs(Reveal.Value - reveal) > 0.01) throw new InvalidOperationException("Read-only test changed the selected live media or reveal.");
            return new Dictionary<string, object> { { "ok", true }, { "designEdition", "10 - Nebula" }, { "denseLinesRemoved", true }, { "bannerRemoved", true }, { "richEffects", ambience.Rich }, { "auroraMoved", auroraMoved }, { "hoverAndTiltExercised", effectsExercised }, { "wallpaperAccent", followAccent }, { "previewedThemeAccent", libraryAccent }, { "wallpaperColoursFound", activeSeeds != null }, { "customUiColorContrastPassed", true }, { "followThemeMode", UiPalette.Mode }, { "wallpaperMonitorCount", wallpaperLink.MonitorCount }, { "libraryCount", libraryCount }, { "filteredCount", filteredCount }, { "activeMediaPath", activePath }, { "reveal", reveal }, { "videoMetadataLoaded", videoMetadata }, { "videoPlayheadAdvanced", playheadAdvanced }, { "controlBounds", bounds }, { "compactControlBoundsPassed", true }, { "diagnosticsLoaded", true }, { "liveWritesRequested", false }, { "samplePictures", sampleArt.Count }, { "layout", layout } };
        }
        /// <summary>Where the named controls sit in the captured picture, for callouts in the documentation.</summary>
        private Dictionary<string, object> Bounds(params string[] names)
        {
            var found = new Dictionary<string, object>();
            foreach (string name in names)
            {
                var element = Find<FrameworkElement>(name);
                if (element == null || !element.IsVisible || element.ActualWidth <= 0) continue;
                Point origin = element.TransformToAncestor((Visual)window.Content).Transform(new Point());
                found[name] = new[] { origin.X, origin.Y, element.ActualWidth, element.ActualHeight };
            }
            return found;
        }
        private void Capture(string path)
        {
            CaptureVisual((FrameworkElement)window.Content, path);
        }
        private void CaptureVisual(FrameworkElement visual, string path)
        {
            visual.UpdateLayout();
            var target = new RenderTargetBitmap((int)Math.Ceiling(visual.ActualWidth), (int)Math.Ceiling(visual.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            target.Render(visual); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(target));
            using (var output = File.Create(path)) encoder.Save(output);
        }
        private void ReportError(Exception ex) { string text = ex.Message; AddLog("未完成：" + text); Label("StatusText").Text = "操作未完成：" + text; if (!disposed && !testMode) MessageBox.Show(window, text, "DreamSkin Studio", MessageBoxButton.OK, MessageBoxImage.Warning); }
        private static SolidColorBrush Brush(string hex) { return UiPalette.Resolve(hex); }
        private void OpenFolder(string path) { if (!Directory.Exists(path)) { MessageBox.Show(window, "目录尚不存在：" + path, "DreamSkin Studio"); return; } Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        public void Dispose() { disposed = true; ambience.Dispose(); wallpaperLink.Dispose(); refreshTimer.Stop(); revealTimer.Stop(); Find<MediaElement>("ArtworkVideo").Stop(); Find<MediaElement>("LibraryVideo").Stop(); }
    }

    internal static class StudioSelfTest
    {
        public static void Run(string[] args)
        {
            string folder = args.Length > 1 ? Path.GetFullPath(args[1]) : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "qa");
            Directory.CreateDirectory(folder);
            var app = new Application(); Window window;
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DreamSkinStudio.MainWindow.xaml")) window = (Window)XamlReader.Load(stream);
            window.WindowStartupLocation = WindowStartupLocation.Manual; window.Left = -20000; window.Top = -20000; window.ShowActivated = false; window.ShowInTaskbar = false;
            UiPalette.Load(window, EngineBridge.StateRoot);
            // Optional third argument: a folder of sample pictures to show instead of the library's own.
            // Those runs also light the window from the pictures, whatever colour mode is saved.
            string samples = args.Length > 2 ? Path.GetFullPath(args[2]) : null;
            if (samples != null) UiPalette.FollowForThisSession(window);
            var controller = new StudioController(window, true, samples);
            window.Loaded += delegate
            {
                window.Dispatcher.BeginInvoke(new Action(async delegate
                {
                    object report;
                    try { report = await controller.RunReadOnlySelfTest(folder); }
                    catch (Exception ex) { report = new { ok = false, error = ex.ToString() }; Environment.ExitCode = 1; }
                    File.WriteAllText(Path.Combine(folder, "report.json"), new JavaScriptSerializer { MaxJsonLength = 4194304 }.Serialize(report), Encoding.UTF8);
                    window.Close();
                }));
            };
            window.Closed += delegate { controller.Dispose(); };
            app.Run(window);
        }
    }
}
