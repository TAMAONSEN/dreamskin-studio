using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace DreamSkinStudio
{
    /// <summary>
    /// Studio-only colours. These brushes stay mutable so existing drawing and
    /// DynamicResource references update without recreating the window.
    /// This class never changes a Codex theme or the selected wallpaper.
    ///
    /// The Studio is always dark: a near-black base lit by three "glow" hues.
    /// Paper = window base, Surface = smoked-glass cards, Solid = opaque
    /// popups, Field/Hover/Line = translucent control tints, Ink/Muted/Subtle =
    /// text, Accent/Accent2 = the gradient used by primary actions.
    /// In follow mode the hues come from the current wallpaper (falling back to
    /// the theme's own colours); in manual mode they derive from one picked hex.
    /// </summary>
    public static class UiPalette
    {
        public const string DefaultHex = "#8B7CF6";
        private const string SettingsFileName = "studio-ui-settings.json";
        private const double GlowLuminance = 0.19;
        private static readonly Color BaseCharcoal = Color.FromRgb(0x0A, 0x0B, 0x10);
        private static readonly Color InkWhite = Color.FromRgb(0xF5, 0xF6, 0xFA);
        private static readonly Color DarkOnAccent = Color.FromRgb(0x0E, 0x10, 0x14);
        private static readonly Duration Fade = new Duration(TimeSpan.FromMilliseconds(900));

        // WPF seals styles and freezes ordinary brush resources when possible.
        // A live binding makes CanFreeze false; update its Animatable source
        // instead of assigning Brush.Color (which would remove the binding).
        private static readonly PaletteSource Source = new PaletteSource();
        public static readonly SolidColorBrush Paper = BoundBrush("PaperColor");
        public static readonly SolidColorBrush Solid = BoundBrush("SolidColor");
        public static readonly SolidColorBrush Surface = BoundBrush("SurfaceColor");
        public static readonly SolidColorBrush Ink = BoundBrush("InkColor");
        public static readonly SolidColorBrush Muted = BoundBrush("MutedColor");
        public static readonly SolidColorBrush Subtle = BoundBrush("SubtleColor");
        public static readonly SolidColorBrush Field = BoundBrush("FieldColor");
        public static readonly SolidColorBrush Hover = BoundBrush("HoverColor");
        public static readonly SolidColorBrush Line = BoundBrush("LineColor");
        public static readonly SolidColorBrush Accent = BoundBrush("AccentColor");
        public static readonly SolidColorBrush Accent2 = BoundBrush("Accent2Color");
        public static readonly SolidColorBrush OnAccent = BoundBrush("OnAccentColor");
        public static readonly SolidColorBrush AccentSoft = BoundBrush("AccentSoftColor");
        public static readonly SolidColorBrush Glow1 = BoundBrush("Glow1Color");
        public static readonly SolidColorBrush Glow2 = BoundBrush("Glow2Color");
        public static readonly SolidColorBrush Glow3 = BoundBrush("Glow3Color");
        public static readonly LinearGradientBrush AccentGradient = BoundGradient(new Point(0, 0), new Point(1, 1), "AccentColor", "Accent2Color");
        public static readonly LinearGradientBrush AccentGradientH = BoundGradient(new Point(0, 0.5), new Point(1, 0.5), "AccentColor", "Accent2Color");
        public static readonly LinearGradientBrush TitleGradient = BoundGradient(new Point(0, 0.5), new Point(1, 0.5), "InkColor", "TitleEndColor");

        private static Color[] wallpaperSeeds;
        private static Dictionary<string, object> themeColors;
        private static string signature = "";

        public static string Hex { get; private set; }
        public static string Mode { get; private set; }
        public static string ManualHex { get; private set; }
        public static Color InkColor { get { return Ink.Color; } }
        public static double ContrastRatio { get { return Contrast(Paper.Color, Ink.Color); } }

        static UiPalette()
        {
            Mode = "follow-theme";
            ManualHex = DefaultHex;
            ApplyManualColors(null, DefaultHex);
        }

        public static void Load(Window window, string stateRoot)
        {
            string path = SettingsPath(stateRoot);
            string accent = DefaultHex;
            string mode = "follow-theme";
            if (File.Exists(path))
            {
                // Invalid user settings must not prevent the Studio opening.
                // Read/permission errors deliberately remain visible to callers.
                string json = File.ReadAllText(path, Encoding.UTF8);
                if (json.Length <= 16384)
                {
                    try
                    {
                        var serializer = new JavaScriptSerializer { MaxJsonLength = 16384 };
                        var values = serializer.Deserialize<Dictionary<string, object>>(json);
                        object saved;
                        if (values != null && values.TryGetValue("accent", out saved) && saved is string)
                        {
                            accent = Normalize((string)saved);
                            mode = "manual"; // Previous releases persisted only accent.
                        }
                        object savedMode;
                        if (values != null && values.TryGetValue("mode", out savedMode) && savedMode is string)
                        {
                            string candidate = ((string)savedMode).Trim().ToLowerInvariant();
                            if (candidate == "manual" || candidate == "follow-theme") mode = candidate;
                        }
                    }
                    catch (ArgumentException) { accent = DefaultHex; }
                    catch (InvalidOperationException) { accent = DefaultHex; }
                    catch (FormatException) { accent = DefaultHex; }
                }
            }
            Mode = mode;
            ManualHex = accent;
            if (mode == "follow-theme" && (wallpaperSeeds != null || themeColors != null)) ApplyTheme(window, null);
            else ApplyManualColors(window, accent);
        }

        public static void Apply(Window window, string hex)
        {
            string normalized = Normalize(hex);
            ApplyManualColors(window, normalized);
            ManualHex = normalized;
            Mode = "manual";
        }

        private static void ApplyManualColors(Window window, string normalized)
        {
            // One hand-picked colour: the second and third hues are its
            // neighbours on the colour wheel, so any pick gives a coherent set.
            Color seed = Parse(normalized);
            Build(window, seed, Rotate(seed, 38), Rotate(seed, -44));
        }

        /// <summary>
        /// Follow mode. Read-only mapping from the current wallpaper (see
        /// <see cref="SetWallpaperSeeds"/>) or, failing that, the active Codex
        /// theme's colours; never saves settings or changes media. Passing
        /// null re-applies the last known theme colours.
        /// </summary>
        public static void ApplyTheme(Window window, IDictionary<string, object> colors)
        {
            if (colors != null && colors.Count > 0) themeColors = new Dictionary<string, object>(colors);
            if (Mode != "follow-theme") return;
            Color[] seeds = wallpaperSeeds ?? ThemeSeeds();
            if (seeds == null) { ApplyManualColors(window, DefaultHex); return; }
            Build(window, seeds[0], seeds[1], seeds[2]);
        }

        /// <summary>Vivid hues sampled from the wallpaper on screen; null clears them.</summary>
        public static void SetWallpaperSeeds(Window window, Color[] seeds)
        {
            wallpaperSeeds = seeds != null && seeds.Length >= 3 ? seeds : null;
            if (Mode == "follow-theme") ApplyTheme(window, null);
        }

        private static Color[] ThemeSeeds()
        {
            if (themeColors == null) return null;
            Color? accent = ThemeColor(themeColors, "accent");
            if (!accent.HasValue || Saturation(accent.Value) < 0.12) return null;
            Color second = ThemeColor(themeColors, "secondary") ?? ThemeColor(themeColors, "accentAlt") ?? Rotate(accent.Value, 38);
            if (HueDistance(accent.Value, second) < 20 || Saturation(second) < 0.12) second = Rotate(accent.Value, 38);
            return new[] { accent.Value, second, Rotate(accent.Value, -44) };
        }

        private static void Build(Window window, Color seedA, Color seedB, Color seedC)
        {
            Color accent = Tone(seedA, 0.70);
            Color accent2 = Tone(seedB, 0.68);
            Color glow1 = GlowTone(seedA), glow2 = GlowTone(seedB), glow3 = GlowTone(seedC);
            Color paper = Mix(BaseCharcoal, glow1, 0.07);
            Color solid = Mix(paper, Colors.White, 0.075);
            Color lifted = Mix(paper, Colors.White, 0.06);
            Color onAccent = Contrast(accent, DarkOnAccent) >= Contrast(accent, Colors.White) ? DarkOnAccent : Colors.White;

            var target = new Dictionary<DependencyProperty, Color>
            {
                { PaletteSource.PaperColorProperty, paper },
                { PaletteSource.SolidColorProperty, solid },
                { PaletteSource.SurfaceColorProperty, Color.FromArgb(0xA6, lifted.R, lifted.G, lifted.B) },
                { PaletteSource.InkColorProperty, InkWhite },
                { PaletteSource.MutedColorProperty, Color.FromRgb(0xB6, 0xBB, 0xC9) },
                { PaletteSource.SubtleColorProperty, Color.FromRgb(0x82, 0x88, 0x99) },
                { PaletteSource.FieldColorProperty, Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF) },
                { PaletteSource.HoverColorProperty, Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF) },
                { PaletteSource.LineColorProperty, Color.FromArgb(0x1C, 0xFF, 0xFF, 0xFF) },
                { PaletteSource.AccentColorProperty, accent },
                { PaletteSource.Accent2ColorProperty, accent2 },
                { PaletteSource.OnAccentColorProperty, onAccent },
                { PaletteSource.AccentSoftColorProperty, Color.FromArgb(0x3A, accent.R, accent.G, accent.B) },
                { PaletteSource.TitleEndColorProperty, Mix(InkWhite, accent, 0.62) },
                { PaletteSource.Glow1ColorProperty, glow1 },
                { PaletteSource.Glow2ColorProperty, glow2 },
                { PaletteSource.Glow3ColorProperty, glow3 }
            };

            if (window != null) window.Dispatcher.VerifyAccess();
            Source.Dispatcher.VerifyAccess();
            string next = String.Join("|", new List<Color>(target.Values).ConvertAll(delegate(Color value) { return value.ToString(CultureInfo.InvariantCulture); }).ToArray());
            // The first palette of a window appears at once; later changes glide.
            bool animate = window != null && window.IsLoaded && SystemParameters.ClientAreaAnimation && signature.Length > 0;
            if (next != signature)
            {
                signature = next;
                foreach (var pair in target) Move(pair.Key, pair.Value, animate);
            }
            Hex = String.Format(CultureInfo.InvariantCulture, "#{0:X2}{1:X2}{2:X2}", accent.R, accent.G, accent.B);

            if (window != null)
            {
                window.Resources["Paper"] = Paper;
                window.Resources["Solid"] = Solid;
                window.Resources["Surface"] = Surface;
                window.Resources["Ink"] = Ink;
                window.Resources["Muted"] = Muted;
                window.Resources["Subtle"] = Subtle;
                window.Resources["Field"] = Field;
                window.Resources["Hover"] = Hover;
                window.Resources["Line"] = Line;
                window.Resources["Accent"] = Accent;
                window.Resources["Accent2"] = Accent2;
                window.Resources["OnAccent"] = OnAccent;
                window.Resources["AccentSoft"] = AccentSoft;
                window.Resources["Glow1"] = Glow1;
                window.Resources["Glow2"] = Glow2;
                window.Resources["Glow3"] = Glow3;
                window.Resources["AccentGradient"] = AccentGradient;
                window.Resources["AccentGradientH"] = AccentGradientH;
                window.Resources["TitleGradient"] = TitleGradient;
            }
        }

        private static void Move(DependencyProperty property, Color to, bool animate)
        {
            Color from = (Color)Source.GetValue(property);
            Source.SetValue(property, to);
            if (!animate || from == to) { Source.BeginAnimation(property, null); return; }
            // The base value already holds the target, so the property keeps
            // it once this animation stops.
            Source.BeginAnimation(property, new ColorAnimation(from, to, Fade)
            {
                FillBehavior = FillBehavior.Stop,
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
            });
        }

        /// <summary>A gradient stop that tracks a palette colour, for effect brushes built in code.</summary>
        internal static GradientStop Stop(string property, double offset)
        {
            var stop = new GradientStop { Offset = offset };
            BindingOperations.SetBinding(stop, GradientStop.ColorProperty, new Binding(property) { Source = Source, Mode = BindingMode.OneWay });
            return stop;
        }

        /// <summary>Persist only the selected Studio mode. The caller refreshes theme colours after enabling follow.</summary>
        public static void SetMode(Window window, string stateRoot, string mode)
        {
            if (mode == null) throw new ArgumentNullException("mode");
            string normalized = mode.Trim().ToLowerInvariant();
            if (normalized != "manual" && normalized != "follow-theme")
                throw new ArgumentException("Mode must be follow-theme or manual.", "mode");
            if (window != null) window.Dispatcher.VerifyAccess();
            Source.Dispatcher.VerifyAccess();
            Persist(stateRoot, normalized, ManualHex);
            Mode = normalized;
        }

        /// <summary>Follow the wallpaper until the window closes, leaving the saved choice untouched (documentation screenshots).</summary>
        internal static void FollowForThisSession(Window window)
        {
            Mode = "follow-theme";
            ApplyTheme(window, null);
        }

        public static void Save(string stateRoot)
        {
            Persist(stateRoot, "manual", ManualHex);
            Mode = "manual";
        }

        private static void Persist(string stateRoot, string mode, string accent)
        {
            string path = SettingsPath(stateRoot);
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temporary = Path.Combine(directory, ".studio-ui-settings-" + Guid.NewGuid().ToString("N") + ".tmp");
            byte[] bytes = new UTF8Encoding(false).GetBytes("{\n  \"mode\": \"" + mode + "\",\n  \"accent\": \"" + accent + "\"\n}\n");
            try
            {
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                    FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    output.Write(bytes, 0, bytes.Length);
                    output.Flush(true);
                }
                // Same-directory replace/move makes the persisted settings an
                // all-or-nothing update. Never fall back to truncating the file.
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally
            {
                // Do not replace the original save error with a cleanup error.
                try { if (File.Exists(temporary)) File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        public static void Reset(Window window, string stateRoot)
        {
            Apply(window, DefaultHex);
            Save(stateRoot);
        }

        /// <summary>A fixed brush for a literal colour that is not part of the palette.</summary>
        public static SolidColorBrush Resolve(string hex)
        {
            if (hex == null) throw new ArgumentNullException("hex");
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            brush.Freeze();
            return brush;
        }

        private static SolidColorBrush BoundBrush(string property)
        {
            var brush = new SolidColorBrush();
            BindingOperations.SetBinding(brush, SolidColorBrush.ColorProperty,
                new Binding(property) { Source = Source, Mode = BindingMode.OneWay });
            return brush;
        }

        private static LinearGradientBrush BoundGradient(Point start, Point end, string first, string second)
        {
            var brush = new LinearGradientBrush { StartPoint = start, EndPoint = end };
            brush.GradientStops.Add(Stop(first, 0));
            brush.GradientStops.Add(Stop(second, 1));
            return brush;
        }

        // Animatable so palette changes can glide instead of snapping.
        private sealed class PaletteSource : Animatable
        {
            private static DependencyProperty Register(string name) { return DependencyProperty.Register(name, typeof(Color), typeof(PaletteSource), new PropertyMetadata(Colors.Transparent)); }
            public static readonly DependencyProperty PaperColorProperty = Register("PaperColor");
            public static readonly DependencyProperty SolidColorProperty = Register("SolidColor");
            public static readonly DependencyProperty SurfaceColorProperty = Register("SurfaceColor");
            public static readonly DependencyProperty InkColorProperty = Register("InkColor");
            public static readonly DependencyProperty MutedColorProperty = Register("MutedColor");
            public static readonly DependencyProperty SubtleColorProperty = Register("SubtleColor");
            public static readonly DependencyProperty FieldColorProperty = Register("FieldColor");
            public static readonly DependencyProperty HoverColorProperty = Register("HoverColor");
            public static readonly DependencyProperty LineColorProperty = Register("LineColor");
            public static readonly DependencyProperty AccentColorProperty = Register("AccentColor");
            public static readonly DependencyProperty Accent2ColorProperty = Register("Accent2Color");
            public static readonly DependencyProperty OnAccentColorProperty = Register("OnAccentColor");
            public static readonly DependencyProperty AccentSoftColorProperty = Register("AccentSoftColor");
            public static readonly DependencyProperty TitleEndColorProperty = Register("TitleEndColor");
            public static readonly DependencyProperty Glow1ColorProperty = Register("Glow1Color");
            public static readonly DependencyProperty Glow2ColorProperty = Register("Glow2Color");
            public static readonly DependencyProperty Glow3ColorProperty = Register("Glow3Color");
            public Color PaperColor { get { return (Color)GetValue(PaperColorProperty); } }
            public Color SolidColor { get { return (Color)GetValue(SolidColorProperty); } }
            public Color SurfaceColor { get { return (Color)GetValue(SurfaceColorProperty); } }
            public Color InkColor { get { return (Color)GetValue(InkColorProperty); } }
            public Color MutedColor { get { return (Color)GetValue(MutedColorProperty); } }
            public Color SubtleColor { get { return (Color)GetValue(SubtleColorProperty); } }
            public Color FieldColor { get { return (Color)GetValue(FieldColorProperty); } }
            public Color HoverColor { get { return (Color)GetValue(HoverColorProperty); } }
            public Color LineColor { get { return (Color)GetValue(LineColorProperty); } }
            public Color AccentColor { get { return (Color)GetValue(AccentColorProperty); } }
            public Color Accent2Color { get { return (Color)GetValue(Accent2ColorProperty); } }
            public Color OnAccentColor { get { return (Color)GetValue(OnAccentColorProperty); } }
            public Color AccentSoftColor { get { return (Color)GetValue(AccentSoftColorProperty); } }
            public Color TitleEndColor { get { return (Color)GetValue(TitleEndColorProperty); } }
            public Color Glow1Color { get { return (Color)GetValue(Glow1ColorProperty); } }
            public Color Glow2Color { get { return (Color)GetValue(Glow2ColorProperty); } }
            public Color Glow3Color { get { return (Color)GetValue(Glow3ColorProperty); } }
            protected override Freezable CreateInstanceCore() { return new PaletteSource(); }
        }

        private static string SettingsPath(string stateRoot)
        {
            if (String.IsNullOrWhiteSpace(stateRoot)) throw new ArgumentException("State directory is required.", "stateRoot");
            return Path.Combine(Path.GetFullPath(stateRoot), SettingsFileName);
        }

        private static string Normalize(string hex)
        {
            if (hex == null) throw new ArgumentNullException("hex");
            string value = hex.Trim();
            if (!Regex.IsMatch(value, "^#[0-9a-fA-F]{6}$"))
                throw new FormatException("请输入 #RRGGBB，例如 #8B7CF6。");
            return value.ToUpperInvariant();
        }

        private static Color Parse(string hex)
        {
            return Color.FromRgb(Byte.Parse(hex.Substring(1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture),
                Byte.Parse(hex.Substring(3, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture),
                Byte.Parse(hex.Substring(5, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
        }

        private static Color? ThemeColor(IDictionary<string, object> colors, string key)
        {
            object value;
            if (!colors.TryGetValue(key, out value) || !(value is string)) return null;
            string text = ((string)value).Trim();
            // Theme palette channels are opaque RGB. Invalid channels are
            // skipped rather than making the whole live refresh fail.
            if (!Regex.IsMatch(text, "^#[0-9a-fA-F]{6}$")) return null;
            return Parse(text);
        }

        // ---- colour maths ---------------------------------------------------

        /// <summary>Same hue as the seed, at a fixed lightness that reads on the dark base.</summary>
        private static Color Tone(Color seed, double lightness)
        {
            double h, s, l; ToHsl(seed, out h, out s, out l);
            // Blues and violets are dim at equal lightness; lift them a little.
            if (h > 215 && h < 295) lightness += 0.04;
            return FromHsl(h, Math.Min(s, 0.92), lightness);
        }

        /// <summary>Same hue, with lightness chosen so every hue glows equally bright behind text.</summary>
        private static Color GlowTone(Color seed)
        {
            double h, s, l; ToHsl(seed, out h, out s, out l);
            s = Math.Min(s, 0.9);
            double low = 0.05, high = 0.85;
            for (int step = 0; step < 18; step++)
            {
                double middle = (low + high) / 2;
                if (Luminance(FromHsl(h, s, middle)) < GlowLuminance) low = middle; else high = middle;
            }
            return FromHsl(h, s, (low + high) / 2);
        }

        private static Color Rotate(Color seed, double degrees)
        {
            double h, s, l; ToHsl(seed, out h, out s, out l);
            return FromHsl(h + degrees, s, l);
        }

        private static double Saturation(Color color) { double h, s, l; ToHsl(color, out h, out s, out l); return s; }

        private static double HueDistance(Color first, Color second)
        {
            double h1, h2, s, l; ToHsl(first, out h1, out s, out l); ToHsl(second, out h2, out s, out l);
            double difference = Math.Abs(h1 - h2) % 360;
            return difference > 180 ? 360 - difference : difference;
        }

        internal static void ToHsl(Color color, out double h, out double s, out double l)
        {
            double r = color.R / 255.0, g = color.G / 255.0, b = color.B / 255.0;
            double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), delta = max - min;
            l = (max + min) / 2;
            if (delta < 1e-9) { h = 0; s = 0; return; }
            s = delta / (1 - Math.Abs(2 * l - 1));
            if (max == r) h = 60 * (((g - b) / delta) % 6);
            else if (max == g) h = 60 * ((b - r) / delta + 2);
            else h = 60 * ((r - g) / delta + 4);
            if (h < 0) h += 360;
        }

        internal static Color FromHsl(double h, double s, double l)
        {
            h = ((h % 360) + 360) % 360;
            s = Math.Max(0, Math.Min(1, s)); l = Math.Max(0, Math.Min(1, l));
            double chroma = (1 - Math.Abs(2 * l - 1)) * s, sector = h / 60;
            double x = chroma * (1 - Math.Abs(sector % 2 - 1)), m = l - chroma / 2;
            double r = 0, g = 0, b = 0;
            if (sector < 1) { r = chroma; g = x; }
            else if (sector < 2) { r = x; g = chroma; }
            else if (sector < 3) { g = chroma; b = x; }
            else if (sector < 4) { g = x; b = chroma; }
            else if (sector < 5) { r = x; b = chroma; }
            else { r = chroma; b = x; }
            return Color.FromRgb((byte)Math.Round((r + m) * 255), (byte)Math.Round((g + m) * 255), (byte)Math.Round((b + m) * 255));
        }

        private static Color Mix(Color first, Color second, double amount)
        {
            return Color.FromRgb((byte)Math.Round(first.R + (second.R - first.R) * amount),
                (byte)Math.Round(first.G + (second.G - first.G) * amount),
                (byte)Math.Round(first.B + (second.B - first.B) * amount));
        }

        private static double Contrast(Color first, Color second)
        {
            double a = Luminance(first), b = Luminance(second);
            return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
        }

        private static double Luminance(Color color)
        {
            return 0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) + 0.0722 * Linear(color.B);
        }

        private static double Linear(byte channel)
        {
            double value = channel / 255.0;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }
    }
}
