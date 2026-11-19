using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;

namespace DreamSkinStudio
{
    /// <summary>Picks the dominant vivid hues of a picture so the Studio can light itself to match.</summary>
    internal static class WallpaperColors
    {
        private const int Bins = 36;

        /// <summary>Three vivid seed colours, most dominant first; null for a near-monochrome picture.</summary>
        public static Color[] Extract(BitmapSource bitmap)
        {
            if (bitmap == null || bitmap.PixelWidth < 2 || bitmap.PixelHeight < 2) return null;
            BitmapSource source = bitmap;
            double scale = 48.0 / Math.Max(bitmap.PixelWidth, bitmap.PixelHeight);
            if (scale < 1) source = new TransformedBitmap(bitmap, new ScaleTransform(scale, scale));
            var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
            int width = converted.PixelWidth, height = converted.PixelHeight, stride = width * 4;
            var pixels = new byte[stride * height];
            converted.CopyPixels(pixels, stride, 0);

            var weights = new double[Bins]; var sines = new double[Bins]; var cosines = new double[Bins];
            int vivid = 0, total = 0;
            for (int i = 0; i < pixels.Length; i += 4)
            {
                if (pixels[i + 3] < 128) continue;
                total++;
                double b = pixels[i] / 255.0, g = pixels[i + 1] / 255.0, r = pixels[i + 2] / 255.0;
                double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), delta = max - min;
                if (max < 0.22 || delta / max < 0.28) continue; // too dark or too grey to carry a hue
                double hue = max == r ? 60 * (((g - b) / delta) % 6) : max == g ? 60 * ((b - r) / delta + 2) : 60 * ((r - g) / delta + 4);
                if (hue < 0) hue += 360;
                // Saturated, bright pixels decide the mood; skin and haze barely count.
                double saturation = delta / max, weight = saturation * saturation * (0.35 + 0.65 * max);
                int bin = (int)(hue / 10) % Bins; double radians = hue * Math.PI / 180;
                weights[bin] += weight; sines[bin] += Math.Sin(radians) * weight; cosines[bin] += Math.Cos(radians) * weight;
                vivid++;
            }
            if (total == 0 || vivid < total * 0.04) return null;

            var smooth = new double[Bins];
            for (int i = 0; i < Bins; i++) smooth[i] = weights[(i + Bins - 1) % Bins] * 0.6 + weights[i] + weights[(i + 1) % Bins] * 0.6;
            var blocked = new bool[Bins];
            int first = Strongest(smooth, blocked);
            if (first < 0) return null;
            double hue1 = Centre(first, sines, cosines); Block(blocked, first, 5);
            int second = Strongest(smooth, blocked);
            bool hasSecond = second >= 0 && smooth[second] >= smooth[first] * 0.14;
            double hue2 = hasSecond ? Centre(second, sines, cosines) : hue1 + 38;
            if (hasSecond) Block(blocked, second, 4);
            int third = Strongest(smooth, blocked);
            double hue3 = third >= 0 && smooth[third] >= smooth[first] * 0.08 ? Centre(third, sines, cosines) : hue1 - 44;
            return new[] { UiPalette.FromHsl(hue1, 0.86, 0.6), UiPalette.FromHsl(hue2, 0.86, 0.6), UiPalette.FromHsl(hue3, 0.86, 0.6) };
        }

        private static int Strongest(double[] smooth, bool[] blocked)
        {
            int best = -1;
            for (int i = 0; i < Bins; i++) if (!blocked[i] && smooth[i] > 0 && (best < 0 || smooth[i] > smooth[best])) best = i;
            return best;
        }

        private static double Centre(int bin, double[] sines, double[] cosines)
        {
            double sine = 0, cosine = 0;
            for (int offset = -1; offset <= 1; offset++) { int i = (bin + offset + Bins) % Bins; sine += sines[i]; cosine += cosines[i]; }
            double degrees = Math.Atan2(sine, cosine) * 180 / Math.PI;
            return degrees < 0 ? degrees + 360 : degrees;
        }

        private static void Block(bool[] blocked, int bin, int radius)
        {
            for (int offset = -radius; offset <= radius; offset++) blocked[(bin + offset + Bins) % Bins] = true;
        }

        /// <summary>A small copy of what an element currently shows (UI thread); used for playing videos.</summary>
        public static BitmapSource Snapshot(FrameworkElement element, int width)
        {
            if (element == null || element.ActualWidth < 1 || element.ActualHeight < 1) return null;
            int height = Math.Max(1, (int)Math.Round(width * element.ActualHeight / element.ActualWidth));
            var drawing = new DrawingVisual();
            using (var context = drawing.RenderOpen())
                context.DrawRectangle(new VisualBrush(element) { Stretch = Stretch.Fill }, null, new Rect(0, 0, width, height));
            var target = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            target.Render(drawing); target.Freeze();
            return target;
        }
    }

    /// <summary>
    /// Small previews for the collection: pictures are decoded directly and
    /// videos use the thumbnail Windows already keeps for the file.
    /// Work happens on one background STA thread; results are frozen.
    /// </summary>
    internal static class Thumbnails
    {
        internal sealed class Result { public BitmapSource Image; public Color[] Seeds; }

        [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItemImageFactory { [PreserveSig] int GetImage(NativeSize size, int flags, out IntPtr bitmap); }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeSize { public int Width, Height; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string path, IntPtr context, [MarshalAs(UnmanagedType.LPStruct)] Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);
        [DllImport("gdi32.dll")]
        private static extern bool DeleteObject(IntPtr handle);
        private const int BiggerSizeOk = 0x1, ThumbnailOnly = 0x8;

        private static readonly Dictionary<string, Task<Result>> Cache = new Dictionary<string, Task<Result>>(StringComparer.OrdinalIgnoreCase);
        private static readonly BlockingCollection<Action> Jobs = new BlockingCollection<Action>();
        private static Thread worker;

        /// <summary>UI thread only. The task never faults; a failed preview has a null Image.</summary>
        public static Task<Result> Get(string path, bool video)
        {
            if (String.IsNullOrEmpty(path) || !File.Exists(path)) return Task.FromResult(new Result());
            string key = path + "|" + File.GetLastWriteTimeUtc(path).Ticks;
            Task<Result> known;
            if (Cache.TryGetValue(key, out known)) return known;
            var completion = new TaskCompletionSource<Result>();
            Cache[key] = completion.Task;
            if (worker == null)
            {
                worker = new Thread(delegate() { foreach (Action job in Jobs.GetConsumingEnumerable()) job(); }) { IsBackground = true, Name = "DreamSkin thumbnails" };
                worker.SetApartmentState(ApartmentState.STA);
                worker.Start();
            }
            Jobs.Add(delegate { completion.SetResult(Load(path, video)); });
            return completion.Task;
        }

        private static Result Load(string path, bool video)
        {
            var result = new Result();
            try
            {
                result.Image = video ? ShellImage(path, 320, 180) : Decode(path, 320);
                result.Seeds = WallpaperColors.Extract(result.Image);
            }
            // Previews are decorative: an unreadable or codec-less file simply
            // keeps its placeholder icon and the theme's own colours.
            catch (Exception) { }
            return result;
        }

        private static BitmapSource Decode(string path, int width)
        {
            var image = new BitmapImage();
            image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.DecodePixelWidth = width; image.UriSource = new Uri(path); image.EndInit();
            image.Freeze();
            return image;
        }

        private static BitmapSource ShellImage(string path, int width, int height)
        {
            IShellItemImageFactory factory;
            SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out factory);
            IntPtr handle;
            int status;
            try { status = factory.GetImage(new NativeSize { Width = width, Height = height }, BiggerSizeOk | ThumbnailOnly, out handle); }
            finally { Marshal.ReleaseComObject(factory); }
            if (status != 0 || handle == IntPtr.Zero) return null;
            try
            {
                var source = Imaging.CreateBitmapSourceFromHBitmap(handle, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                // Copy now: the GDI bitmap is released below, and the alpha
                // channel of shell thumbnails is not meaningful.
                var copy = new CachedBitmap(new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                copy.Freeze();
                return copy;
            }
            finally { DeleteObject(handle); }
        }
    }

    /// <summary>
    /// The Studio's lighting and motion: drifting aurora, a light that follows
    /// the pointer, card edges that catch that light, a tilting preview, the
    /// navigation glider and staggered page entrances. Purely visual; it reads
    /// no settings and never touches the theme engine.
    /// </summary>
    internal sealed class Ambience : IDisposable
    {
        private const double MaxTiltX = 7, MaxTiltY = 10, StagePadX = 28, StagePadY = 52;
        // The floor reflection shows the lowest part of the picture, just below it.
        private const double MirrorPart = 0.28, MirrorGap = 0.03;
        // Frames per second. Every step of the slow aurora repaints the whole
        // window, so it runs well below the display rate; measured on the home
        // page this cut the render thread's work by about half with no visible change.
        private const int DriftRate = 10, StageRate = 24;
        private static readonly Point Away = new Point(-4000, -4000);

        private readonly Window window;
        private readonly bool rich;
        private readonly List<AnimationClock> perpetual = new List<AnimationClock>();
        private readonly List<KeyValuePair<Border, RadialGradientBrush>> edges = new List<KeyValuePair<Border, RadialGradientBrush>>();
        private readonly FrameworkElement root, spotlight, stage;
        private readonly FrameworkElement[] blobs;
        private readonly TranslateTransform spotMove = new TranslateTransform();
        private readonly Viewport3D frame;
        private readonly PerspectiveCamera camera;
        private readonly MeshGeometry3D mesh;
        private readonly AxisAngleRotation3D pitch, yaw;
        private readonly Border viewport, glare;
        private readonly TranslateTransform glareMove = new TranslateTransform();
        private readonly TranslateTransform gliderMove = new TranslateTransform();
        private readonly MeshGeometry3D mirrorMesh = new MeshGeometry3D();
        private readonly System.Windows.Shapes.Rectangle mirrorSource = new System.Windows.Shapes.Rectangle();
        private double spotX, spotY, spotTargetX, spotTargetY, spotAlpha, spotTargetAlpha;
        private double tiltX, tiltY, tiltTargetX, tiltTargetY, glareAlpha, glareTargetAlpha, glareX, glareTargetX;
        private bool looping, active = true, disposed;

        internal int Frames { get; private set; }
        internal bool Rich { get { return rich; } }

        public Ambience(Window target)
        {
            window = target;
            // Without a capable GPU (remote sessions, basic drivers) the
            // Studio keeps its look but stays still.
            rich = SystemParameters.ClientAreaAnimation && (RenderCapability.Tier >> 16) >= 2;
            root = Find<FrameworkElement>("RootGrid");
            blobs = new[] { Find<FrameworkElement>("Blob1"), Find<FrameworkElement>("Blob2"), Find<FrameworkElement>("Blob3"), Find<FrameworkElement>("Blob4") };
            spotlight = Find<FrameworkElement>("Spotlight");
            spotlight.RenderTransform = spotMove;
            stage = Find<FrameworkElement>("HomeStage");
            frame = Find<Viewport3D>("ArtworkFrame");
            camera = (PerspectiveCamera)frame.Camera;
            var plane = Find<Viewport2DVisual3D>("ArtworkPlane");
            mesh = (MeshGeometry3D)plane.Geometry;
            var rotations = ((Transform3DGroup)plane.Transform).Children;
            pitch = (AxisAngleRotation3D)((RotateTransform3D)rotations[0]).Rotation;
            yaw = (AxisAngleRotation3D)((RotateTransform3D)rotations[1]).Rotation;
            viewport = Find<Border>("ArtworkViewport");
            glare = Find<Border>("ArtworkGlare");
            ((Brush)glare.Background).RelativeTransform = glareMove;
            Find<FrameworkElement>("NavGlider").RenderTransform = gliderMove;
            Find<System.Windows.Shapes.Rectangle>("Grain").Fill = GrainBrush();

            if (rich)
            {
                // A second plane shares the preview's rotation and shows it upside down, fading out.
                mirrorSource.Fill = new VisualBrush(viewport) { Stretch = Stretch.Fill };
                mirrorSource.OpacityMask = new LinearGradientBrush(Color.FromArgb(0, 0, 0, 0), Color.FromArgb(0x6B, 0, 0, 0), new Point(0, 1 - MirrorPart), new Point(0, 1));
                mirrorMesh.TextureCoordinates = new PointCollection { new Point(0, 1), new Point(0, 1 - MirrorPart), new Point(1, 1 - MirrorPart), new Point(1, 1) };
                mirrorMesh.TriangleIndices = new Int32Collection { 0, 1, 2, 0, 2, 3 };
                frame.Children.Add(new ModelVisual3D
                {
                    Content = new GeometryModel3D(mirrorMesh, new DiffuseMaterial(new VisualBrush(mirrorSource) { Stretch = Stretch.Fill })),
                    Transform = plane.Transform
                });
            }
            root.SizeChanged += delegate { PlaceBlobs(); };
            frame.SizeChanged += delegate { FitCamera(); };
            viewport.SizeChanged += delegate { FitCamera(); };
            window.Loaded += delegate { PlaceBlobs(); FitCamera(); CollectEdges(); if (rich) { StartDrift(); StartFlow(); StartPulse(); AddDepth(); Intro(); } };
            if (!rich) return;
            window.PreviewMouseMove += delegate(object sender, MouseEventArgs e) { Track(e); };
            window.MouseLeave += delegate { Release(); };
            window.Deactivated += delegate { Release(); };
            stage.MouseLeave += delegate { tiltTargetX = 0; tiltTargetY = 0; glareTargetAlpha = 0; Loop(); };
        }

        private T Find<T>(string name) where T : class
        {
            var found = window.FindName(name) as T;
            if (found == null) throw new InvalidOperationException("Layout element is missing: " + name);
            return found;
        }

        // ---- aurora ---------------------------------------------------------

        private void PlaceBlobs()
        {
            double width = root.ActualWidth, height = root.ActualHeight;
            if (width < 1 || height < 1) return;
            var anchors = new[] { new Point(0.08, 0.10), new Point(0.94, 0.90), new Point(0.74, 0.02), new Point(0.26, 1.02) };
            for (int i = 0; i < blobs.Length; i++)
            {
                Canvas.SetLeft(blobs[i], anchors[i].X * width - blobs[i].Width / 2);
                Canvas.SetTop(blobs[i], anchors[i].Y * height - blobs[i].Height / 2);
            }
        }

        private void StartDrift()
        {
            var travel = new[] { new Vector(150, 110), new Vector(-170, -120), new Vector(-130, 150), new Vector(160, -100) };
            for (int i = 0; i < blobs.Length; i++)
            {
                var move = new TranslateTransform(); blobs[i].RenderTransform = move;
                // Unequal periods keep the four lights from ever repeating in step.
                Run(move, TranslateTransform.XProperty, -travel[i].X, travel[i].X, 17 + i * 5, true, DriftRate);
                Run(move, TranslateTransform.YProperty, -travel[i].Y, travel[i].Y, 23 + i * 4, true, DriftRate);
            }
        }

        private void Run(Animatable target, DependencyProperty property, double from, double to, double seconds, bool swing, int rate)
        {
            var animation = new DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds)) { RepeatBehavior = RepeatBehavior.Forever, AutoReverse = swing };
            if (swing) animation.EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut };
            Timeline.SetDesiredFrameRate(animation, rate);
            var clock = animation.CreateClock();
            target.ApplyAnimationClock(property, clock);
            perpetual.Add(clock);
            if (!active) clock.Controller.Pause();
        }

        private static Brush GrainBrush()
        {
            // Fine film grain keeps the large gradients from banding.
            const int size = 128;
            var random = new Random(7); var pixels = new byte[size * size * 4];
            for (int i = 0; i < pixels.Length; i += 4)
            {
                byte value = (byte)random.Next(256);
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255;
            }
            var bitmap = BitmapSource.Create(size, size, 96, 96, PixelFormats.Bgr32, null, pixels, size * 4); bitmap.Freeze();
            var brush = new ImageBrush(bitmap) { TileMode = TileMode.Tile, ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, size, size), Stretch = Stretch.None };
            brush.Freeze();
            return brush;
        }

        // ---- flowing stage edge and pulses ----------------------------------

        private void StartFlow()
        {
            var turn = new RotateTransform(0, 0.5, 0.5);
            var flow = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1), RelativeTransform = turn };
            flow.GradientStops.Add(new GradientStop(Color.FromArgb(0, 255, 255, 255), 0));
            flow.GradientStops.Add(new GradientStop(Color.FromArgb(0, 255, 255, 255), 0.52));
            flow.GradientStops.Add(UiPalette.Stop("AccentColor", 0.8));
            flow.GradientStops.Add(UiPalette.Stop("Accent2Color", 1));
            Find<Border>("StageFlow").BorderBrush = flow;
            Run(turn, RotateTransform.AngleProperty, 0, 360, 9, false, StageRate);
        }

        private void StartPulse()
        {
            // The ring sits on the stage, which already repaints for the video.
            var ring = Find<FrameworkElement>("LivePulse");
            var grow = new ScaleTransform(1, 1); ring.RenderTransform = grow; ring.RenderTransformOrigin = new Point(0.5, 0.5);
            Run(grow, ScaleTransform.ScaleXProperty, 1, 2.8, 1.8, false, StageRate);
            Run(grow, ScaleTransform.ScaleYProperty, 1, 2.8, 1.8, false, StageRate);
            var fade = new DoubleAnimation(0.7, 0, TimeSpan.FromSeconds(1.8)) { RepeatBehavior = RepeatBehavior.Forever };
            Timeline.SetDesiredFrameRate(fade, StageRate);
            var clock = fade.CreateClock(); ring.ApplyAnimationClock(UIElement.OpacityProperty, clock); perpetual.Add(clock);
            if (!active) clock.Controller.Pause();
        }

        private void AddDepth()
        {
            frame.Effect = new DropShadowEffect { BlurRadius = 38, ShadowDepth = 14, Direction = 270, Opacity = 0.5, Color = Colors.Black };
            Find<FrameworkElement>("LibraryFrame").Effect = new DropShadowEffect { BlurRadius = 38, ShadowDepth = 14, Direction = 270, Opacity = 0.5, Color = Colors.Black };
        }

        private void Intro()
        {
            var content = Find<FrameworkElement>("ContentRoot");
            var scale = new ScaleTransform(1, 1); content.RenderTransform = scale; content.RenderTransformOrigin = new Point(0.5, 0.5);
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            content.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(520)) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.975, 1, TimeSpan.FromMilliseconds(620)) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.975, 1, TimeSpan.FromMilliseconds(620)) { EasingFunction = ease });
            foreach (FrameworkElement blob in blobs)
            {
                double rest = blob.Opacity;
                blob.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, rest, TimeSpan.FromMilliseconds(1400)) { EasingFunction = ease });
            }
        }

        // ---- pointer light, card edges and stage tilt -----------------------

        private void CollectEdges()
        {
            object cardStyle = window.TryFindResource("Card");
            foreach (Border border in Descendants(root).OfType<Border>())
            {
                if (!ReferenceEquals(border.Style, cardStyle) && !"reveal".Equals(border.Tag)) continue;
                var brush = new RadialGradientBrush { MappingMode = BrushMappingMode.Absolute, RadiusX = 250, RadiusY = 250, Center = Away, GradientOrigin = Away };
                brush.GradientStops.Add(UiPalette.Stop("AccentColor", 0));
                brush.GradientStops.Add(UiPalette.Stop("LineColor", 1));
                border.BorderBrush = brush;
                edges.Add(new KeyValuePair<Border, RadialGradientBrush>(border, brush));
            }
        }

        private static IEnumerable<FrameworkElement> Descendants(DependencyObject parent)
        {
            foreach (object child in LogicalTreeHelper.GetChildren(parent))
            {
                var element = child as FrameworkElement;
                if (element == null) continue;
                yield return element;
                foreach (FrameworkElement nested in Descendants(element)) yield return nested;
            }
        }

        private void Track(MouseEventArgs e)
        {
            if (!active) return;
            Illuminate(delegate(UIElement element) { return e.GetPosition(element); });
            if (stage.IsVisible && stage.IsMouseOver && stage.ActualWidth > 1)
            {
                Point over = e.GetPosition(stage);
                double x = over.X / stage.ActualWidth * 2 - 1, y = over.Y / stage.ActualHeight * 2 - 1;
                Lean(x, y);
            }
            Loop();
        }

        /// <summary>Move the pointer light, and let every visible card edge catch it.</summary>
        private void Illuminate(Func<UIElement, Point> locate)
        {
            foreach (var edge in edges)
            {
                if (!edge.Key.IsVisible) continue;
                Point local = locate(edge.Key);
                edge.Value.Center = local; edge.Value.GradientOrigin = local;
            }
            Point position = locate(root);
            spotTargetX = position.X - spotlight.Width / 2; spotTargetY = position.Y - spotlight.Height / 2;
            if (spotAlpha < 0.01) { spotX = spotTargetX; spotY = spotTargetY; }
            spotTargetAlpha = 1;
        }

        /// <summary>Lean the preview towards a point; both coordinates run from -1 to 1 across the stage.</summary>
        private void Lean(double x, double y)
        {
            tiltTargetY = Math.Max(-1, Math.Min(1, x)) * MaxTiltY;
            tiltTargetX = Math.Max(-1, Math.Min(1, y)) * MaxTiltX;
            glareTargetX = -x * 0.55; glareTargetAlpha = 1;
        }

        private void Release()
        {
            foreach (var edge in edges) { edge.Value.Center = Away; edge.Value.GradientOrigin = Away; }
            spotTargetAlpha = 0; tiltTargetX = 0; tiltTargetY = 0; glareTargetAlpha = 0;
            Loop();
        }

        private void Loop()
        {
            if (looping || disposed) return;
            looping = true; CompositionTarget.Rendering += Step;
        }

        private void Step(object sender, EventArgs e)
        {
            Frames++;
            spotX += (spotTargetX - spotX) * 0.16; spotY += (spotTargetY - spotY) * 0.16;
            spotAlpha += (spotTargetAlpha - spotAlpha) * 0.1;
            tiltX += (tiltTargetX - tiltX) * 0.1; tiltY += (tiltTargetY - tiltY) * 0.1;
            glareAlpha += (glareTargetAlpha - glareAlpha) * 0.1; glareX += (glareTargetX - glareX) * 0.1;
            bool settled = Math.Abs(spotTargetX - spotX) < 0.3 && Math.Abs(spotTargetY - spotY) < 0.3 && Math.Abs(spotTargetAlpha - spotAlpha) < 0.01
                && Math.Abs(tiltTargetX - tiltX) < 0.02 && Math.Abs(tiltTargetY - tiltY) < 0.02
                && Math.Abs(glareTargetAlpha - glareAlpha) < 0.01 && Math.Abs(glareTargetX - glareX) < 0.003;
            if (settled)
            {
                spotX = spotTargetX; spotY = spotTargetY; spotAlpha = spotTargetAlpha; tiltX = tiltTargetX; tiltY = tiltTargetY;
                glareAlpha = glareTargetAlpha; glareX = glareTargetX;
                looping = false; CompositionTarget.Rendering -= Step;
            }
            Present();
        }

        private void Present()
        {
            spotMove.X = spotX; spotMove.Y = spotY; spotlight.Opacity = spotAlpha * 0.2;
            pitch.Angle = tiltX; yaw.Angle = tiltY;
            glareMove.X = glareX; glare.Opacity = glareAlpha;
        }

        private void FitCamera()
        {
            double width = frame.ActualWidth, height = frame.ActualHeight;
            if (width < 1 || height < 1 || viewport.ActualWidth < 1 || viewport.ActualHeight < 1) return;
            // The plane is two units wide; its height follows the media.
            double half = viewport.ActualHeight / viewport.ActualWidth;
            mesh.Positions = new Point3DCollection { new Point3D(-1, half, 0), new Point3D(-1, -half, 0), new Point3D(1, -half, 0), new Point3D(1, half, 0) };
            double below = 0;
            if (rich)
            {
                double top = -half - MirrorGap, bottom = top - 2 * half * MirrorPart;
                mirrorMesh.Positions = new Point3DCollection { new Point3D(-1, top, 0), new Point3D(-1, bottom, 0), new Point3D(1, bottom, 0), new Point3D(1, top, 0) };
                // The reflection samples an off-screen copy, which needs its own layout.
                mirrorSource.Width = viewport.ActualWidth; mirrorSource.Height = viewport.ActualHeight;
                mirrorSource.Measure(new Size(viewport.ActualWidth, viewport.ActualHeight));
                mirrorSource.Arrange(new Rect(0, 0, viewport.ActualWidth, viewport.ActualHeight));
                // Only the upper part of the reflection is bright enough to need room.
                below = MirrorGap + 2 * half * MirrorPart * 0.45;
            }
            // Frame the picture together with the visible part of its reflection.
            double extent = half + below / 2;
            double tangent = Math.Tan(camera.FieldOfView * Math.PI / 360);
            double fitX = Math.Max(0.2, (width - StagePadX * 2) / width), fitY = Math.Max(0.2, (height - StagePadY * 2) / height);
            double byWidth = 1 / (tangent * fitX), byHeight = extent * (width / height) / (tangent * fitY);
            camera.Position = new Point3D(0, -below / 2, Math.Max(byWidth, byHeight));
        }

        // ---- navigation glider and page entrances ---------------------------

        public void MoveNav(double offset, bool animate)
        {
            if (!animate || !rich) { gliderMove.BeginAnimation(TranslateTransform.YProperty, null); gliderMove.Y = offset; return; }
            gliderMove.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(offset, TimeSpan.FromMilliseconds(420))
            { EasingFunction = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.45 } });
        }

        /// <summary>Cards of a page rise into place one after another.</summary>
        public void Enter(FrameworkElement page)
        {
            if (!rich) return;
            object cardStyle = window.TryFindResource("Card");
            int index = 0;
            foreach (FrameworkElement item in Descendants(page))
            {
                var border = item as Border;
                bool card = border != null && ReferenceEquals(border.Style, cardStyle);
                if (!card && !"reveal".Equals(item.Tag) && !"rise".Equals(item.Tag)) continue;
                Rise(item, TimeSpan.FromMilliseconds(55 * index++));
            }
        }

        public void Rise(FrameworkElement item, TimeSpan delay)
        {
            if (!rich) return;
            var move = new TranslateTransform(); item.RenderTransform = move;
            TimeSpan end = delay + TimeSpan.FromMilliseconds(460);
            // Key frames hold the hidden state through the delay, so nothing
            // flashes before its turn and the resting values stay untouched.
            var fade = new DoubleAnimationUsingKeyFrames { Duration = end, FillBehavior = FillBehavior.Stop };
            fade.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            fade.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(delay)));
            fade.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(end), new CubicEase { EasingMode = EasingMode.EaseOut }));
            var lift = new DoubleAnimationUsingKeyFrames { Duration = end, FillBehavior = FillBehavior.Stop };
            lift.KeyFrames.Add(new DiscreteDoubleKeyFrame(22, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            lift.KeyFrames.Add(new DiscreteDoubleKeyFrame(22, KeyTime.FromTimeSpan(delay)));
            lift.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(end), new QuinticEase { EasingMode = EasingMode.EaseOut }));
            item.BeginAnimation(UIElement.OpacityProperty, fade);
            move.BeginAnimation(TranslateTransform.YProperty, lift);
        }

        /// <summary>New media fades in instead of popping.</summary>
        public void Reveal(UIElement media)
        {
            if (!rich) return;
            media.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(380)) { FillBehavior = FillBehavior.Stop });
        }

        // ---- lifetime -------------------------------------------------------

        /// <summary>Everything rests while the window is in the background.</summary>
        public void SetActive(bool value)
        {
            if (active == value || disposed) return;
            active = value;
            foreach (AnimationClock clock in perpetual) { if (value) clock.Controller.Resume(); else clock.Controller.Pause(); }
            if (!value && rich) Release();
        }

        /// <summary>Self-test only: light the window as if the pointer rested at a point, leaning the preview by x and y (-1 to 1).</summary>
        internal void Pose(Point pointer, double x, double y)
        {
            Illuminate(delegate(UIElement element) { return root.TranslatePoint(pointer, element); });
            Lean(x, y);
            spotX = spotTargetX; spotY = spotTargetY; spotAlpha = spotTargetAlpha;
            tiltX = tiltTargetX; tiltY = tiltTargetY; glareAlpha = glareTargetAlpha; glareX = glareTargetX;
            Present();
        }

        /// <summary>Self-test only: let the posed window settle back.</summary>
        internal void Unpose() { Release(); }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (looping) { looping = false; CompositionTarget.Rendering -= Step; }
            foreach (AnimationClock clock in perpetual) clock.Controller.Stop();
            perpetual.Clear();
        }
    }
}
