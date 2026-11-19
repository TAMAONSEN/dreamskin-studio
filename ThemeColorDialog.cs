using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;

namespace DreamSkinStudio
{
    /// <summary>Edits Studio and the current Codex theme as two separate scopes.</summary>
    internal sealed class ThemeColorDialog : Window
    {
        private readonly Window paletteOwner;
        private readonly TextBox managerHex;
        private readonly TextBlock managerMessage;
        private readonly CheckBox followTheme;
        private readonly TextBox codexAccent;
        private readonly TextBox codexBackground;
        private readonly TextBox codexPanel;
        private readonly TextBox codexText;
        private readonly TextBlock codexTheme;
        private readonly TextBlock codexMessage;
        private readonly StackPanel codexInputs;
        private readonly Button codexSave;
        private readonly Button codexReset;
        private readonly Button codexRefresh;
        private readonly Dictionary<TextBox, string> loadedAdvanced = new Dictionary<TextBox, string>();
        private string currentThemeId = "";
        private bool codexBusy;
        private bool canReset;
        private bool closed;
        private Dictionary<string, object> lastThemeColors;

        public bool CodexChanged { get; private set; }
        internal bool ReadOnlyDataReady { get { return currentThemeId.Length > 0 && !codexBusy; } }

        public ThemeColorDialog(Window owner)
        {
            if (owner == null) throw new ArgumentNullException("owner");
            paletteOwner = owner;
            Owner = owner;
            Title = "DreamSkin · 主题配色";
            if (owner.Style != null) Style = owner.Style;
            Resources.MergedDictionaries.Add(owner.Resources);
            WindowStyle = WindowStyle.SingleBorderWindow;
            ResizeMode = ResizeMode.CanResize;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ShowInTaskbar = false;
            MaxWidth = Math.Max(300, SystemParameters.WorkArea.Width - 40);
            MaxHeight = Math.Max(260, SystemParameters.WorkArea.Height - 40);
            Width = Math.Min(650, MaxWidth);
            Height = Math.Min(720, MaxHeight);
            MinWidth = Math.Min(450, MaxWidth);
            MinHeight = Math.Min(360, MaxHeight);
            FontFamily = owner.FontFamily;
            FontSize = 14;
            FontWeight = FontWeights.SemiBold;
            Background = UiPalette.Paper;
            Foreground = UiPalette.Ink;
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;

            var frame = new Grid();
            frame.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            frame.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var scroll = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Padding = new Thickness(0, 0, 12, 8)
            };
            var content = new StackPanel();
            scroll.Content = content;
            frame.Children.Add(scroll);
            content.Children.Add(Label("选择喜欢的颜色。", 25));
            var lead = Label("管理器和 Codex 的配色分别保存，背景与透出度保持原设置。", 14);
            lead.Margin = new Thickness(0, 6, 0, 20);
            lead.Foreground = UiPalette.Muted;
            content.Children.Add(lead);

            var managerSection = Section("01  管理器界面配色", "只改变 DreamSkin Studio 的光与强调色，不修改 Codex。");
            content.Children.Add(managerSection);
            followTheme = new CheckBox { Content = "自动取色：跟随当前壁纸与主题", IsChecked = UiPalette.Mode == "follow-theme", FontSize = 15, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 8, 0, 15) };
            managerSection.Children.Add(followTheme);
            followTheme.Click += async delegate { await ChangeFollowMode(); };
            managerHex = ColorEntry("手动管理器颜色", "ManagerColorHex", UiPalette.ManualHex);
            managerSection.Children.Add(Presets(managerHex));
            managerSection.Children.Add(EntryWithPicker(managerHex));
            var managerActions = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
            var applyManager = ButtonFor("应用管理器配色", "ApplyManagerColor");
            applyManager.Click += delegate { ApplyManagerColor(false); };
            var resetManager = ButtonFor("恢复默认配色", "ResetManagerColor");
            resetManager.Click += delegate { ApplyManagerColor(true); };
            managerActions.Children.Add(applyManager);
            managerActions.Children.Add(resetManager);
            managerSection.Children.Add(managerActions);
            managerMessage = StatusLabel("输入 HEX，或从预设和拾色器选择。", "ManagerColorStatus");
            managerSection.Children.Add(managerMessage);

            var separator = new Border { Height = 1, Background = UiPalette.Line, Margin = new Thickness(0, 22, 0, 20) };
            content.Children.Add(separator);
            var codexSection = Section("02  Codex 当前主题配色", "保存后可回到主窗口重新应用；这里不会重启 Codex。");
            content.Children.Add(codexSection);
            codexTheme = Label("正在读取当前主题…", 14);
            codexTheme.Name = "CurrentColorTheme";
            codexTheme.Margin = new Thickness(0, 6, 0, 10);
            codexSection.Children.Add(codexTheme);
            codexInputs = new StackPanel { IsEnabled = false };
            codexSection.Children.Add(codexInputs);
            codexAccent = ColorEntry("强调色", "CodexAccentHex", "");
            codexInputs.Children.Add(Presets(codexAccent));
            codexInputs.Children.Add(EntryWithPicker(codexAccent));
            codexInputs.Children.Add(Label("强调色用于当前主题的重点按钮与装饰。", 14));
            var advanced = new Expander
            {
                Header = "高级：背景、面板与文字",
                FontSize = 14,
                FontWeight = FontWeights.Bold,
                Foreground = UiPalette.Ink,
                Margin = new Thickness(0, 14, 0, 0)
            };
            var advancedFields = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            codexBackground = ColorEntry("背景色（留空保持）", "CodexBackgroundHex", "");
            codexPanel = ColorEntry("面板色（留空保持）", "CodexPanelHex", "");
            codexText = ColorEntry("文字色（留空保持）", "CodexTextHex", "");
            AddAdvanced(advancedFields, "背景色", codexBackground);
            AddAdvanced(advancedFields, "面板色", codexPanel);
            AddAdvanced(advancedFields, "文字色", codexText);
            var advancedHint = Label("留空会保留该项；文字和背景请选用反差清晰的颜色。", 14);
            advancedHint.Foreground = UiPalette.Muted;
            advancedFields.Children.Add(advancedHint);
            advanced.Content = advancedFields;
            codexInputs.Children.Add(advanced);
            var codexActions = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
            codexSave = ButtonFor("保存 Codex 配色", "SaveCodexColors");
            codexSave.IsEnabled = false;
            codexSave.Click += async delegate { await SaveCodexColors(); };
            codexReset = ButtonFor("恢复主题原配色", "ResetCodexColors");
            codexReset.IsEnabled = false;
            codexReset.Click += async delegate { await ResetCodexColors(); };
            codexRefresh = ButtonFor("重新读取", "RefreshCodexColors");
            codexRefresh.Click += async delegate { await LoadCodexColors(); };
            codexActions.Children.Add(codexSave);
            codexActions.Children.Add(codexReset);
            codexActions.Children.Add(codexRefresh);
            codexSection.Children.Add(codexActions);
            codexMessage = StatusLabel("正在读取…", "CodexColorStatus");
            codexSection.Children.Add(codexMessage);

            var footer = new DockPanel { Margin = new Thickness(0, 12, 0, 0), LastChildFill = false };
            Grid.SetRow(footer, 1);
            var close = ButtonFor("完成", "CloseColorDialog");
            close.Margin = new Thickness(0);
            close.IsCancel = true;
            close.Click += delegate { Close(); };
            DockPanel.SetDock(close, Dock.Right);
            footer.Children.Add(close);
            frame.Children.Add(footer);
            Content = new Border { Background = UiPalette.Paper, Padding = new Thickness(22, 16, 22, 16), Child = frame };
            Loaded += async delegate { await LoadCodexColors(); };
            Closing += delegate(object sender, System.ComponentModel.CancelEventArgs e)
            {
                if (!codexBusy) return;
                e.Cancel = true;
                codexMessage.Text = "正在处理当前操作，请完成后关闭。";
            };
            Closed += delegate { closed = true; };
        }

        private static TextBlock Label(string text, double size)
        {
            return new TextBlock { Text = text, FontSize = Math.Max(14, size), FontWeight = FontWeights.Bold,
                Foreground = UiPalette.Ink, TextWrapping = TextWrapping.Wrap, LineHeight = Math.Max(21, size * 1.42) };
        }

        private static StackPanel Section(string title, string explanation)
        {
            var panel = new StackPanel();
            panel.Children.Add(Label(title, 18));
            var hint = Label(explanation, 14);
            hint.Foreground = UiPalette.Muted;
            hint.Margin = new Thickness(0, 6, 0, 10);
            panel.Children.Add(hint);
            return panel;
        }

        private static TextBlock StatusLabel(string text, string name)
        {
            var label = Label(text, 14);
            label.Name = name;
            label.Margin = new Thickness(0, 8, 0, 0);
            AutomationProperties.SetHelpText(label, text);
            return label;
        }

        private static TextBox ColorEntry(string description, string name, string value)
        {
            var box = new TextBox { Text = value ?? "", Name = name, MinHeight = 38,
                FontSize = 16, FontWeight = FontWeights.Bold, FontFamily = new FontFamily("Consolas"),
                Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 8, 0),
                Foreground = UiPalette.Ink, Background = UiPalette.Field, CaretBrush = UiPalette.Ink,
                BorderBrush = UiPalette.Line, BorderThickness = new Thickness(1), MaxLength = 32,
                ToolTip = description + "，例如 #FF0041", VerticalContentAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(box, description);
            return box;
        }

        private Button ButtonFor(string caption, string name)
        {
            var button = new Button { Content = caption, Name = name, FontSize = 14, FontWeight = FontWeights.Bold,
                Padding = new Thickness(13, 9, 13, 9), Margin = new Thickness(0, 0, 8, 7), MinHeight = 40,
                Foreground = UiPalette.Ink, Background = UiPalette.Field, BorderBrush = UiPalette.Line,
                BorderThickness = new Thickness(1), Cursor = System.Windows.Input.Cursors.Hand };
            var inherited = TryFindResource(typeof(Button)) as Style;
            var style = new Style(typeof(Button), inherited);
            // Keep shared styling, but avoid fixed owner hover colors becoming
            // unreadable when the manager's mutable palette changes.
            var template = new ControlTemplate(typeof(Button));
            var surface = new FrameworkElementFactory(typeof(Border));
            surface.Name = "ColorButtonSurface";
            surface.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
            surface.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
            surface.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
            surface.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
            surface.SetValue(Border.CornerRadiusProperty, new CornerRadius(9));
            var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
            presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
            surface.AppendChild(presenter);
            template.VisualTree = surface;
            var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
            hover.Setters.Add(new Setter(Border.BackgroundProperty, UiPalette.Hover, "ColorButtonSurface"));
            template.Triggers.Add(hover);
            var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
            disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.45, "ColorButtonSurface"));
            template.Triggers.Add(disabled);
            var focused = new Trigger { Property = UIElement.IsKeyboardFocusedProperty, Value = true };
            focused.Setters.Add(new Setter(Border.BorderBrushProperty, UiPalette.Accent, "ColorButtonSurface"));
            template.Triggers.Add(focused);
            style.Setters.Add(new Setter(Control.TemplateProperty, template));
            button.Style = style;
            AutomationProperties.SetName(button, caption);
            return button;
        }

        private WrapPanel Presets(TextBox target)
        {
            var row = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
            var choices = new[] { new[] { "星紫", "#8B7CF6" }, new[] { "玫红", "#F0446A" },
                new[] { "金色", "#D4B976" }, new[] { "薄荷", "#389E86" },
                new[] { "淡紫", "#BA9CFF" }, new[] { "靛蓝", "#4169E1" } };
            foreach (string[] choice in choices)
            {
                string hex = choice[1];
                var preset = ButtonFor(choice[0], "Preset" + hex.Substring(1));
                preset.Padding = new Thickness(9, 7, 9, 7);
                preset.MinHeight = 36;
                var caption = new StackPanel { Orientation = Orientation.Horizontal };
                caption.Children.Add(new Rectangle { Width = 14, Height = 14, Fill = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)),
                    Stroke = UiPalette.Line, StrokeThickness = 1, RadiusX = 4, RadiusY = 4, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center });
                caption.Children.Add(Label(choice[0], 14));
                preset.Content = caption;
                preset.ToolTip = hex;
                preset.Click += delegate { target.Text = hex; target.Focus(); target.SelectAll(); };
                row.Children.Add(preset);
            }
            return row;
        }

        private Grid EntryWithPicker(TextBox entry)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(entry);
            var picker = ButtonFor("选择颜色…", entry.Name + "Picker");
            picker.Margin = new Thickness(0);
            Grid.SetColumn(picker, 1);
            picker.Click += delegate { ChooseColor(entry); };
            row.Children.Add(picker);
            return row;
        }

        private void AddAdvanced(StackPanel container, string title, TextBox entry)
        {
            var label = Label(title, 14);
            label.Margin = new Thickness(0, 0, 0, 6);
            container.Children.Add(label);
            var row = EntryWithPicker(entry);
            row.Margin = new Thickness(0, 0, 0, 10);
            container.Children.Add(row);
        }

        private sealed class NativeColorOwner : System.Windows.Forms.IWin32Window
        {
            private readonly IntPtr handle;
            public NativeColorOwner(IntPtr value) { handle = value; }
            public IntPtr Handle { get { return handle; } }
        }

        private void ChooseColor(TextBox target)
        {
            try
            {
                using (var picker = new System.Windows.Forms.ColorDialog())
                {
                    picker.FullOpen = true;
                    string starting;
                    if (TryHex(target.Text, out starting)) picker.Color = System.Drawing.ColorTranslator.FromHtml(starting);
                    if (picker.ShowDialog(new NativeColorOwner(new WindowInteropHelper(this).Handle)) != System.Windows.Forms.DialogResult.OK) return;
                    target.Text = String.Format(CultureInfo.InvariantCulture, "#{0:X2}{1:X2}{2:X2}", picker.Color.R, picker.Color.G, picker.Color.B);
                }
            }
            catch (Exception ex)
            {
                (target == managerHex ? managerMessage : codexMessage).Text = "无法打开拾色器：" + ex.Message;
            }
        }

        private static bool TryHex(string text, out string normalized)
        {
            normalized = (text ?? "").Trim().ToUpperInvariant();
            if (Regex.IsMatch(normalized, "^#[0-9A-F]{3}$"))
                normalized = "#" + normalized[1] + normalized[1] + normalized[2] + normalized[2] + normalized[3] + normalized[3];
            return Regex.IsMatch(normalized, "^#[0-9A-F]{6}$");
        }

        private void ApplyManagerColor(bool reset)
        {
            string next;
            if (!reset && !TryHex(managerHex.Text, out next))
            {
                managerMessage.Text = "请输入有效 HEX，例如 #FF0041。";
                managerHex.Focus();
                return;
            }
            next = reset ? UiPalette.DefaultHex : managerHex.Text.Trim();
            string old = UiPalette.Hex;
            try
            {
                if (reset) UiPalette.Reset(paletteOwner, EngineBridge.StateRoot);
                else
                {
                    string canonical;
                    TryHex(next, out canonical);
                    UiPalette.Apply(paletteOwner, canonical);
                    UiPalette.Save(EngineBridge.StateRoot);
                }
                managerHex.Text = UiPalette.ManualHex;
                followTheme.IsChecked = false;
                managerMessage.Text = reset ? "已恢复默认配色。Codex 配色保持原设置。" : "管理器配色已保存。Codex 配色保持原设置。";
            }
            catch (Exception ex)
            {
                try { UiPalette.Load(paletteOwner, EngineBridge.StateRoot); if (UiPalette.Mode == "follow-theme" && lastThemeColors != null) UiPalette.ApplyTheme(paletteOwner, lastThemeColors); }
                catch { UiPalette.Apply(paletteOwner, old); }
                followTheme.IsChecked = UiPalette.Mode == "follow-theme";
                managerHex.Text = UiPalette.ManualHex;
                managerMessage.Text = "未能保存，已恢复原界面颜色：" + ex.Message;
            }
        }
        private async Task ChangeFollowMode()
        {
            bool enabled = followTheme.IsChecked == true;
            try
            {
                UiPalette.SetMode(paletteOwner, EngineBridge.StateRoot, enabled ? "follow-theme" : "manual");
                if (enabled)
                {
                    var result = await Task.Run(delegate { return EngineBridge.Call("GetColors"); });
                    UiPalette.ApplyTheme(paletteOwner, Json.Map(Json.Get(result, "colors")));
                }
                if (!enabled) UiPalette.Apply(paletteOwner, UiPalette.ManualHex);
                managerHex.Text = UiPalette.ManualHex;
                managerMessage.Text = enabled ? "已开启跟随：切换主题后，管理器颜色也会更新。" : "已切回手动配色。";
            }
            catch (Exception ex) { followTheme.IsChecked = UiPalette.Mode == "follow-theme"; managerMessage.Text = "未完成：" + ex.Message; }
        }

        private void SetCodexBusy(bool value)
        {
            codexBusy = value;
            codexInputs.IsEnabled = !value && currentThemeId.Length > 0;
            codexSave.IsEnabled = !value && currentThemeId.Length > 0;
            codexReset.IsEnabled = !value && currentThemeId.Length > 0 && canReset;
            codexRefresh.IsEnabled = !value;
        }

        private void FillCodexColors(Dictionary<string, object> data)
        {
            lastThemeColors = Json.Map(Json.Get(data, "colors"));
            currentThemeId = Json.Text(data, "themeId");
            canReset = Json.Bool(data, "canReset");
            var colors = Json.Map(Json.Get(data, "colors"));
            codexTheme.Text = currentThemeId.Length == 0 ? "当前没有可编辑的 Codex 主题。" : "当前主题：" + Json.Text(data, "themeName");
            codexAccent.Text = Json.Text(colors, "accent");
            codexBackground.Text = Json.Text(colors, "background");
            codexPanel.Text = Json.Text(colors, "panel");
            codexText.Text = Json.Text(colors, "text");
            loadedAdvanced[codexBackground] = codexBackground.Text;
            loadedAdvanced[codexPanel] = codexPanel.Text;
            loadedAdvanced[codexText] = codexText.Text;
        }

        private async Task LoadCodexColors()
        {
            if (codexBusy || closed) return;
            SetCodexBusy(true);
            codexMessage.Text = "正在读取当前主题配色…";
            try
            {
                var data = await Task.Run(delegate { return EngineBridge.Call("GetColors"); });
                if (closed) return;
                FillCodexColors(data);
                codexMessage.Text = currentThemeId.Length == 0 ? "请先在主窗口选择并应用一个主题。" : "配色已读取。修改后点击“保存 Codex 配色”。";
            }
            catch (Exception ex)
            {
                currentThemeId = "";
                canReset = false;
                codexTheme.Text = "未能读取当前主题。";
                codexMessage.Text = "读取失败：" + ex.Message;
            }
            finally { if (!closed) SetCodexBusy(false); }
        }

        private bool AddColorArgument(List<string> arguments, TextBox field, string argument, string caption, bool required)
        {
            if (String.IsNullOrWhiteSpace(field.Text) && !required) return true;
            string original;
            if (!required && loadedAdvanced.TryGetValue(field, out original) && String.Equals(field.Text, original, StringComparison.Ordinal)) return true;
            string normalized;
            if (!TryHex(field.Text, out normalized))
            {
                codexMessage.Text = caption + "格式不正确，请输入 #RRGGBB。";
                field.Focus(); field.SelectAll();
                return false;
            }
            arguments.Add(argument); arguments.Add(normalized);
            return true;
        }

        private async Task SaveCodexColors()
        {
            if (codexBusy || currentThemeId.Length == 0) return;
            var arguments = new List<string> { "-ThemeId", currentThemeId };
            if (!AddColorArgument(arguments, codexAccent, "-Accent", "强调色", true) ||
                !AddColorArgument(arguments, codexBackground, "-Background", "背景色", false) ||
                !AddColorArgument(arguments, codexPanel, "-Panel", "面板色", false) ||
                !AddColorArgument(arguments, codexText, "-Text", "文字色", false)) return;
            SetCodexBusy(true);
            codexMessage.Text = "正在保存当前主题配色…";
            try
            {
                var data = await Task.Run(delegate { return EngineBridge.Call("SetColors", arguments.ToArray()); });
                CodexChanged = true;
                if (closed) return;
                FillCodexColors(data);
                codexMessage.Text = "配色已保存。回到主窗口点击“启动 / 重新应用”后生效，背景与透出度保持原设置。";
            }
            catch (Exception ex) { if (!closed) codexMessage.Text = "未能保存：" + ex.Message; }
            finally { if (!closed) SetCodexBusy(false); }
        }

        private async Task ResetCodexColors()
        {
            if (codexBusy || currentThemeId.Length == 0 || !canReset) return;
            string requestedId = currentThemeId;
            SetCodexBusy(true);
            codexMessage.Text = "正在恢复当前主题的原配色…";
            try
            {
                var data = await Task.Run(delegate { return EngineBridge.Call("ResetColors", "-ThemeId", requestedId); });
                CodexChanged = true;
                if (closed) return;
                FillCodexColors(data);
                codexMessage.Text = "已恢复主题原配色。回到主窗口重新应用后生效，背景与透出度保持原设置。";
            }
            catch (Exception ex) { if (!closed) codexMessage.Text = "未能恢复：" + ex.Message; }
            finally { if (!closed) SetCodexBusy(false); }
        }
    }
}
