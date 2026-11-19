using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace DreamSkinStudio
{
    internal sealed class WallpaperLinkPanel : StackPanel, IDisposable
    {
        private readonly ComboBox monitors;
        private readonly CheckBox follow;
        private readonly TextBlock status;
        private readonly TextBlock monitorHint;
        private readonly Button sync, refresh, record, associate;
        private readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        private readonly Func<Task> changed;
        private readonly Action<string> log;
        private readonly bool readOnly;
        private readonly Func<bool> canSync;
        private readonly Action<bool> mutationChanged;
        private bool busy, loading, enabled, disposed;
        internal bool IsMutating { get; private set; }
        private string lastMessage = "";
        internal int MonitorCount { get { return monitors.Items.Count; } }
        internal bool StatusLoaded { get; private set; }
        private string MonitorId { get { var item = monitors.SelectedItem as ComboBoxItem; return item == null ? "" : Json.Text((Dictionary<string, object>)item.Tag, "monitorId"); } }

        public WallpaperLinkPanel(Func<Task> onChanged, Action<string> addLog, bool readOnlyTest, Func<bool> maySync, Action<bool> onMutation)
        {
            changed = onChanged; log = addLog; readOnly = readOnlyTest;
            canSync = maySync; mutationChanged = onMutation;
            Children.Add(Text("Wallpaper Engine 联动", 16));
            var hint = Text("选择屏幕后，可导入一次或开启自动跟随。", 13); hint.FontWeight = FontWeights.Normal; hint.Foreground = UiPalette.Muted; hint.Margin = new Thickness(0, 4, 0, 14); Children.Add(hint);
            monitors = new ComboBox { FontSize = 14, MinHeight = 38 };
            monitors.ToolTip = "选择要跟随的屏幕；读取 Wallpaper Engine 保存的配置。";
            monitors.SelectionChanged += async delegate { if (!loading && !busy) { ShowSelectedHint(); if (enabled && !readOnly) await SaveFollow(); } };
            var chooser = new Grid(); chooser.Children.Add(monitors);
            monitorHint = new TextBlock { Text = "请选择屏幕…", Foreground = UiPalette.Subtle, FontSize = 14, Margin = new Thickness(12, 0, 34, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
            chooser.Children.Add(monitorHint); Children.Add(chooser);
            follow = new CheckBox { Content = "自动跟随（管理器运行时）", FontSize = 14, Margin = new Thickness(0, 14, 0, 14), Foreground = UiPalette.Ink };
            follow.Click += async delegate { if (!readOnly) await SaveFollow(); };
            Children.Add(follow);
            var actions = new WrapPanel();
            sync = new Button { Content = "导入并应用当前壁纸", FontSize = 14, Margin = new Thickness(0, 0, 10, 8), Padding = new Thickness(12, 7, 12, 7) };
            refresh = new Button { Content = "刷新壁纸信息", FontSize = 14, Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(12, 7, 12, 7) };
            sync.Click += async delegate { if (!readOnly) await Sync(false); };
            refresh.Click += async delegate { await LoadStatus(); };
            actions.Children.Add(sync); actions.Children.Add(refresh); Children.Add(actions);
            var sceneActions = new WrapPanel();
            record = new Button { Content = "录制并关联此场景", FontSize = 14, Margin = new Thickness(0, 0, 10, 8), Padding = new Thickness(12, 7, 12, 7) };
            associate = new Button { Content = "关联已有 MP4…", FontSize = 14, Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(12, 7, 12, 7) };
            record.Click += async delegate { if (!readOnly) await PrepareScene(true); };
            associate.Click += async delegate { if (!readOnly) await PrepareScene(false); };
            sceneActions.Children.Add(record); sceneActions.Children.Add(associate); Children.Add(sceneActions);
            status = Text("正在读取壁纸配置…", 14); status.FontWeight = FontWeights.Normal; status.Margin = new Thickness(0, 6, 0, 0); Children.Add(status);
            var limit = Text("视频可直接跟随；场景首次需录制或关联 MP4。录制会打开专用预览窗口，约需一分钟；以后自动复用录像。", 12); limit.FontWeight = FontWeights.Normal; limit.Foreground = UiPalette.Muted; limit.Margin = new Thickness(0, 10, 0, 0); Children.Add(limit);
            timer.Tick += async delegate { if (enabled && !busy && !disposed && !readOnly) await Sync(true); };
            Loaded += async delegate { await LoadStatus(); if (!readOnly) timer.Start(); };
            Unloaded += delegate { timer.Stop(); };
        }
        private TextBlock Text(string value, int size) { return new TextBlock { Text = value, FontSize = size, FontWeight = FontWeights.SemiBold, Foreground = UiPalette.Ink, TextWrapping = TextWrapping.Wrap, LineHeight = size + 7 }; }
        private bool SceneSelected { get { var item = monitors.SelectedItem as ComboBoxItem; return item != null && Json.Text((Dictionary<string, object>)item.Tag, "type") == "scene"; } }
        private void Busy(bool value) { busy = value; monitors.IsEnabled = !value; follow.IsEnabled = !value; sync.IsEnabled = !value && monitors.SelectedItem != null; refresh.IsEnabled = !value; record.IsEnabled = !value && SceneSelected; associate.IsEnabled = !value && SceneSelected; }
        private void ShowSelectedHint()
        {
            var item = monitors.SelectedItem as ComboBoxItem;
            monitorHint.Visibility = item == null ? Visibility.Visible : Visibility.Collapsed;
            if (item == null) { status.Text = "请选择要跟随的屏幕。"; sync.IsEnabled = false; return; }
            var data = (Dictionary<string, object>)item.Tag;
            record.IsEnabled = !busy && SceneSelected; associate.IsEnabled = !busy && SceneSelected;
            // Title first, then what Wallpaper Engine's layout and this wallpaper type mean for syncing.
            status.Inlines.Clear();
            status.Inlines.Add(new System.Windows.Documents.Run(Json.Text(data, "title")) { FontWeight = FontWeights.SemiBold });
            foreach (string detail in new[] { Json.Text(data, "layoutNote"), Json.Text(data, "reason") })
            {
                if (detail.Length == 0) continue;
                status.Inlines.Add(new System.Windows.Documents.LineBreak());
                status.Inlines.Add(new System.Windows.Documents.Run(detail) { Foreground = UiPalette.Muted, FontSize = 13 });
            }
            sync.IsEnabled = !busy;
        }
        internal void SelectMonitorForPreview(string id)
        {
            foreach (ComboBoxItem item in monitors.Items) if (Json.Text((Dictionary<string, object>)item.Tag, "monitorId") == id) { monitors.SelectedItem = item; break; }
        }
        internal async Task LoadStatus()
        {
            if (busy || disposed) return; Busy(true);
            try
            {
                string keep = MonitorId;
                var data = await Task.Run(delegate { return EngineBridge.CallLink("Status"); });
                enabled = Json.Bool(data, "enabled");
                string saved = Json.Text(data, "monitorId"); if (saved.Length > 0) keep = saved;
                loading = true; monitors.Items.Clear();
                var entries = Json.Get(data, "monitorEntries") as System.Collections.IEnumerable;
                if (entries != null) foreach (object raw in entries)
                {
                    var entry = Json.Map(raw); string id = Json.Text(entry, "monitorId");
                    string caption = Json.Text(entry, "label"); if (caption.Length == 0) caption = "屏幕 " + id;
                    var item = new ComboBoxItem { Content = caption + " · " + Json.Text(entry, "title"), Tag = entry };
                    monitors.Items.Add(item); if (id == keep) monitors.SelectedItem = item;
                }
                follow.IsChecked = enabled;
                StatusLoaded = true;
                if (monitors.Items.Count == 0) status.Text = "没有找到 Wallpaper Engine 的已保存壁纸配置。"; else ShowSelectedHint();
            }
            catch (Exception ex) { status.Text = "读取失败：" + ex.Message; }
            finally { loading = false; Busy(false); }
        }
        private async Task SaveFollow()
        {
            if (busy || disposed || !canSync()) { follow.IsChecked = enabled; return; }
            string id = MonitorId; bool requested = follow.IsChecked == true;
            if (id.Length == 0) { follow.IsChecked = false; status.Text = "请先选择要跟随的屏幕。"; return; }
            Busy(true); IsMutating = true; mutationChanged(true);
            try
            {
                await Task.Run(delegate { return EngineBridge.CallLink("SetFollow", "-Enabled", requested ? "true" : "false", "-MonitorId", id); });
                enabled = requested;
                status.Text = requested ? "自动跟随已开启，每 8 秒检查一次；关闭管理器后停止。" : "自动跟随已关闭，仍可手动导入。";
                log(status.Text);
            }
            catch (Exception ex) { follow.IsChecked = enabled; status.Text = "未保存：" + ex.Message; }
            finally { Busy(false); IsMutating = false; mutationChanged(false); }
        }
        private async Task Sync(bool automatic)
        {
            if (busy || disposed || !canSync()) { if (!automatic) status.Text = "请等待当前主题操作完成后再同步。"; return; } string id = MonitorId;
            if (id.Length == 0) { status.Text = "请先选择屏幕。"; return; }
            Busy(true); IsMutating = true; mutationChanged(true);
            try
            {
                var data = await Task.Run(delegate { return EngineBridge.CallLink("Sync", "-MonitorId", id, "-Automatic", automatic ? "true" : "false"); });
                string message = Json.Text(data, "message");
                if (message.Length == 0) message = Json.Bool(data, "changed") ? "已同步当前壁纸。" : "当前壁纸未变化。";
                status.Text = message;
                if (Json.Bool(data, "changed")) { if (lastMessage != message) log(message); await changed(); }
                lastMessage = message;
            }
            catch (Exception ex) { status.Text = "同步未完成：" + ex.Message; }
            finally { Busy(false); IsMutating = false; mutationChanged(false); }
        }
        private async Task PrepareScene(bool capture)
        {
            if (busy || disposed || !canSync() || !SceneSelected) return;
            string id = MonitorId; string outcome = null; bool completed = false;
            Busy(true); IsMutating = true; mutationChanged(true);
            Window owner = Window.GetWindow(this); WindowState oldWindowState = owner.WindowState;
            try
            {
                var snapshot = await Task.Run(delegate { return EngineBridge.CallLink("Status"); });
                var entries = Json.Get(snapshot, "monitorEntries") as System.Collections.IEnumerable;
                var entry = entries == null ? null : entries.Cast<object>().Select(Json.Map).SingleOrDefault(x => Json.Text(x, "monitorId") == id);
                if (entry == null || Json.Text(entry, "type") != "scene") throw new InvalidOperationException("屏幕壁纸已经变化，请刷新后重试。");
                string path;
                if (capture)
                {
                    status.Text = "正在打开专用窗口并录制高清场景，完成后自动返回…";
                    log(status.Text); owner.WindowState = WindowState.Minimized;
                    var result = await Task.Run(delegate { return EngineBridge.RecordWallpaper(Json.Text(entry, "projectPath")); });
                    if (Json.Bool(result, "sourceChanged")) throw new InvalidOperationException("录制时场景源文件变化，请重新录制。");
                    path = Json.Text(result, "path");
                }
                else
                {
                    var picker = new Microsoft.Win32.OpenFileDialog { Title = "选择这个场景对应的已录 MP4", Filter = "MP4 视频|*.mp4", CheckFileExists = true };
                    if (picker.ShowDialog(owner) != true) return;
                    path = picker.FileName;
                }
                await Task.Run(delegate { return EngineBridge.CallLink("RegisterRecording", "-MonitorId", id, "-Path", path,
                    "-ExpectedWorkshopId", Json.Text(entry, "workshopId"), "-ExpectedSceneFingerprint", Json.Text(entry, "sceneFingerprint")); });
                completed = true; outcome = "场景录像已加入收藏并关联，点击「导入并应用当前壁纸」即可切换。";
                log(outcome);
            }
            catch (Exception ex) { outcome = "场景准备未完成：" + ex.Message; }
            finally { owner.WindowState = oldWindowState; Busy(false); IsMutating = false; mutationChanged(false); }
            if (completed) { await LoadStatus(); await changed(); }
            if (outcome != null) status.Text = outcome;
        }
        public void Dispose() { disposed = true; timer.Stop(); }
    }
}
