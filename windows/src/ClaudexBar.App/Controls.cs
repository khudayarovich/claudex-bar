using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Rendering.Composition;
using Avalonia.Rendering.Composition.Animations;
using ClaudexBar.Core;

namespace ClaudexBar.App;

internal static class Palette
{
    public static readonly Color Red = Color.FromRgb(0xFF, 0x45, 0x3A);
    public static readonly Color Yellow = Color.FromRgb(0xFF, 0xD6, 0x0A);
    public static readonly Color Green = Color.FromRgb(0x30, 0xD1, 0x58);
    public static readonly Color Orange = Color.FromRgb(0xFF, 0x9F, 0x0A);
    public static readonly Color ClaudeAccent = Color.FromRgb(0xD9, 0x77, 0x57);
    public static readonly Color CodexAccent = Color.FromArgb(0xEB, 0xFF, 0xFF, 0xFF);
    public static readonly IBrush Primary = new SolidColorBrush(Color.FromArgb(240, 255, 255, 255));
    public static readonly IBrush Secondary = new SolidColorBrush(Color.FromArgb(148, 255, 255, 255));
    public static readonly IBrush Tertiary = new SolidColorBrush(Color.FromArgb(97, 255, 255, 255));
    public static readonly IBrush Track = new SolidColorBrush(Color.FromArgb(31, 255, 255, 255));
    public static readonly IBrush Separator = new SolidColorBrush(Color.FromArgb(20, 255, 255, 255));
    public static readonly IBrush RowHover = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255));

    public static Color Lamp(LampColor c) => c switch { LampColor.Red => Red, LampColor.Yellow => Yellow, _ => Green };

    public static Color Usage(UsageLevel l) => l switch
    {
        UsageLevel.Normal => Green,
        UsageLevel.Elevated => Yellow,
        UsageLevel.High => Orange,
        _ => Red,
    };

    public static Color Lighter(Color c, double f) =>
        Color.FromRgb((byte)(c.R + (255 - c.R) * f), (byte)(c.G + (255 - c.G) * f), (byte)(c.B + (255 - c.B) * f));
}

/// <summary>Underdamped spring (like SwiftUI's .spring(response:dampingFraction:)).</summary>
internal sealed class SpringEase(double response = 0.42, double damping = 0.76, double duration = 0.6) : Easing
{
    public override double Ease(double p)
    {
        if (p >= 1) return 1;
        double t = p * duration, w = 2 * Math.PI / response, z = damping, wd = w * Math.Sqrt(1 - z * z);
        return 1 - Math.Exp(-z * w * t) * (Math.Cos(wd * t) + z * w / wd * Math.Sin(wd * t));
    }
}

/// <summary>The island silhouette: concave top shoulders blending into the screen edge and
/// rounded bottom corners; its child is clipped to the same shape.</summary>
internal sealed class IslandShape : Decorator
{
    public static readonly StyledProperty<double> ShoulderProperty = AvaloniaProperty.Register<IslandShape, double>(nameof(Shoulder), 6);
    public static readonly StyledProperty<double> BottomProperty = AvaloniaProperty.Register<IslandShape, double>(nameof(Bottom), 10);

    static IslandShape()
    {
        AffectsRender<IslandShape>(ShoulderProperty, BottomProperty);
    }

    public double Shoulder { get => GetValue(ShoulderProperty); set => SetValue(ShoulderProperty, value); }
    public double Bottom { get => GetValue(BottomProperty); set => SetValue(BottomProperty, value); }

    public static Geometry Path(Size size, double shoulder, double bottom)
    {
        double w = size.Width, h = size.Height;
        double s = Math.Max(0, Math.Min(shoulder, Math.Min(h / 2, w / 4)));
        double b = Math.Max(0, Math.Min(bottom, Math.Min(h - s, (w - 2 * s) / 2)));
        double left = s, right = w - s;
        var g = new StreamGeometry();
        using var ctx = g.Open();
        ctx.BeginFigure(new Point(0, 0), true);
        ctx.ArcTo(new Point(s, s), new Size(s, s), 0, false, SweepDirection.Clockwise);
        ctx.LineTo(new Point(left, h - b));
        ctx.ArcTo(new Point(left + b, h), new Size(b, b), 0, false, SweepDirection.CounterClockwise);
        ctx.LineTo(new Point(right - b, h));
        ctx.ArcTo(new Point(right, h - b), new Size(b, b), 0, false, SweepDirection.CounterClockwise);
        ctx.LineTo(new Point(right, s));
        ctx.ArcTo(new Point(w, 0), new Size(s, s), 0, false, SweepDirection.Clockwise);
        ctx.EndFigure(true);
        return g;
    }

    public override void Render(DrawingContext context)
    {
        context.DrawGeometry(Brushes.Black, null, Path(Bounds.Size, Shoulder, Bottom));
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var size = base.ArrangeOverride(finalSize);
        Clip = Path(finalSize, Shoulder, Bottom);
        return size;
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == ShoulderProperty || change.Property == BottomProperty) Clip = Path(Bounds.Size, Shoulder, Bottom);
    }
}

/// <summary>A lit lamp disc (radial gradient + glow). Its opacity is animated on the compositor.</summary>
internal sealed class LampDot : Control
{
    public Color Color { get; set; } = Palette.Green;

    public override void Render(DrawingContext context)
    {
        var r = new Rect(Bounds.Size);
        var gradient = new RadialGradientBrush
        {
            Center = new RelativePoint(0.36, 0.3, RelativeUnit.Relative),
            GradientOrigin = new RelativePoint(0.36, 0.3, RelativeUnit.Relative),
            RadiusX = new RelativeScalar(0.75, RelativeUnit.Relative),
            RadiusY = new RelativeScalar(0.75, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Palette.Lighter(Color, 0.45), 0), new GradientStop(Color, 1) },
        };
        context.DrawRectangle(gradient, null, new RoundedRect(r, r.Width / 2),
            new BoxShadows(new BoxShadow { Blur = 6, Spread = 0, Color = Color.FromArgb(200, Color.R, Color.G, Color.B) }));
    }
}

internal sealed class BaseDot : Control
{
    public Color Color { get; set; } = Palette.Green;

    public override void Render(DrawingContext context) =>
        context.DrawEllipse(new SolidColorBrush(Color, 0.17), null, new Rect(Bounds.Size));
}

internal sealed class Lamp : Panel
{
    private readonly BaseDot _base = new();
    private readonly LampDot _lit = new();
    private LampMode _mode = LampMode.Off;
    private bool _reduceMotion;

    public Lamp(Color color, double size)
    {
        Width = Height = size;
        SetColor(color);
        Children.Add(_base);
        Children.Add(_lit);
        _lit.Opacity = 0;
    }

    public void SetColor(Color c)
    {
        _base.Color = c;
        _lit.Color = c;
        _base.InvalidateVisual();
        _lit.InvalidateVisual();
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        Apply(_mode, _reduceMotion, force: true);
    }

    private static double Resting(LampMode m) => m switch
    {
        LampMode.Off => 0,
        LampMode.Dim => 0.42,
        LampMode.Breathing => 0.9,
        _ => 1,
    };

    public void Apply(LampMode mode, bool reduceMotion, bool force = false)
    {
        if (!force && mode == _mode && reduceMotion == _reduceMotion) return;
        _mode = mode;
        _reduceMotion = reduceMotion;
        var visual = ElementComposition.GetElementVisual(_lit);
        if (visual is null)
        {
            _lit.Opacity = Resting(mode);
            return;
        }
        var compositor = visual.Compositor;
        var anim = compositor.CreateScalarKeyFrameAnimation();
        anim.Target = "Opacity";
        if (reduceMotion || mode is LampMode.Off or LampMode.Dim or LampMode.Steady)
        {
            anim.InsertKeyFrame(1f, (float)Resting(mode));
            anim.Duration = TimeSpan.FromMilliseconds(220);
            anim.IterationBehavior = AnimationIterationBehavior.Count;
            anim.IterationCount = 1;
        }
        else if (mode == LampMode.Breathing)
        {
            anim.InsertKeyFrame(0f, 0.72f);
            anim.InsertKeyFrame(1f, 1f);
            anim.Duration = TimeSpan.FromSeconds(1.2);
            anim.Direction = PlaybackDirection.Alternate;
            anim.IterationBehavior = AnimationIterationBehavior.Forever;
        }
        else
        {
            anim.InsertKeyFrame(0f, 1f);
            anim.InsertKeyFrame(0.42f, 1f);
            anim.InsertKeyFrame(0.52f, 0.22f);
            anim.InsertKeyFrame(0.86f, 0.22f);
            anim.InsertKeyFrame(1f, 1f);
            anim.Duration = TimeSpan.FromSeconds(1.0);
            anim.IterationBehavior = AnimationIterationBehavior.Forever;
        }
        visual.StartAnimation("Opacity", anim);
    }
}

/// <summary>Three lamps (red, yellow, green) in a dark capsule; or a single lamp for rows.</summary>
internal sealed class TrafficLight : Border
{
    private readonly Lamp[] _lamps;
    private readonly bool _single;

    public TrafficLight(bool single = false, double lamp = 7)
    {
        _single = single;
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = single ? 0 : 3 };
        _lamps = single
            ? [new Lamp(Palette.Green, lamp + 1)]
            : [new Lamp(Palette.Red, lamp), new Lamp(Palette.Yellow, lamp), new Lamp(Palette.Green, lamp)];
        foreach (var l in _lamps) panel.Children.Add(l);
        Child = panel;
        if (!single)
        {
            Padding = new Thickness(4, 3);
            CornerRadius = new CornerRadius(lamp);
            Background = new SolidColorBrush(Color.FromRgb(0x1A, 0x1A, 0x1A));
            BorderBrush = new SolidColorBrush(Color.FromArgb(23, 255, 255, 255));
            BorderThickness = new Thickness(0.5);
        }
        VerticalAlignment = VerticalAlignment.Center;
    }

    public void Apply(LampTriple t, bool reduceMotion)
    {
        if (_single)
        {
            var (color, mode) = t.Red != LampMode.Off ? (Palette.Red, t.Red)
                : t.Yellow != LampMode.Off ? (Palette.Yellow, t.Yellow) : (Palette.Green, t.Green);
            _lamps[0].SetColor(color);
            _lamps[0].Apply(mode, reduceMotion, force: true);
            return;
        }
        _lamps[0].Apply(t.Red, reduceMotion);
        _lamps[1].Apply(t.Yellow, reduceMotion);
        _lamps[2].Apply(t.Green, reduceMotion);
    }
}

/// <summary>Provider glyph with an optional usage ring around it.</summary>
internal sealed class Glyph : Control
{
    public static readonly StyledProperty<double> FractionProperty = AvaloniaProperty.Register<Glyph, double>(nameof(Fraction), -1);

    static Glyph()
    {
        AffectsRender<Glyph>(FractionProperty);
    }

    public Glyph(Provider provider, double size, bool ring)
    {
        ProviderKind = provider;
        HasRing = ring;
        Width = Height = size;
        Transitions = [new DoubleTransition { Property = FractionProperty, Duration = TimeSpan.FromMilliseconds(600), Easing = new CubicEaseOut() }];
    }

    public Provider ProviderKind { get; }
    public bool HasRing { get; set; }
    public UsageLevel Level { get; set; }
    public double Fraction { get => GetValue(FractionProperty); set => SetValue(FractionProperty, value); }

    public override void Render(DrawingContext ctx)
    {
        var size = Bounds.Size;
        var c = new Point(size.Width / 2, size.Height / 2);
        double outer = Math.Min(size.Width, size.Height) / 2;
        double glyphRadius = outer * (HasRing ? 0.56 : 0.8);
        if (HasRing)
        {
            double r = outer - 1;
            ctx.DrawEllipse(null, new Pen(Palette.Track, 1.75), c, r, r);
            if (Fraction >= 0)
            {
                var pen = new Pen(new SolidColorBrush(Palette.Usage(Level)), 1.75, lineCap: PenLineCap.Round);
                double f = Math.Clamp(Fraction, 0.02, 1);
                if (f >= 0.999) ctx.DrawEllipse(null, pen, c, r, r);
                else
                {
                    double a0 = -Math.PI / 2, a1 = a0 + f * 2 * Math.PI;
                    var g = new StreamGeometry();
                    using (var gc = g.Open())
                    {
                        gc.BeginFigure(new Point(c.X + r * Math.Cos(a0), c.Y + r * Math.Sin(a0)), false);
                        gc.ArcTo(new Point(c.X + r * Math.Cos(a1), c.Y + r * Math.Sin(a1)), new Size(r, r), 0, f > 0.5, SweepDirection.Clockwise);
                        gc.EndFigure(false);
                    }
                    ctx.DrawGeometry(null, pen, g);
                }
            }
        }
        if (ProviderKind == Provider.Claude) DrawStarburst(ctx, c, glyphRadius);
        else DrawCodex(ctx, c, glyphRadius);
    }

    private static void DrawStarburst(DrawingContext ctx, Point c, double r)
    {
        var g = new StreamGeometry();
        using (var gc = g.Open())
        {
            for (int i = 0; i < 10; i++)
            {
                double angle = i / 10.0 * 2 * Math.PI - Math.PI / 2;
                double length = r * (i % 2 == 0 ? 1.0 : 0.8), baseHalf = r * 0.12, tipHalf = r * 0.045, inner = r * 0.16;
                var dir = new Vector(Math.Cos(angle), Math.Sin(angle));
                var perp = new Vector(-dir.Y, dir.X);
                Point P(double along, double across) => c + dir * along + perp * across;
                gc.BeginFigure(P(inner, -baseHalf), true);
                gc.LineTo(P(length, -tipHalf));
                gc.QuadraticBezierTo(P(length + tipHalf * 1.6, 0), P(length, tipHalf));
                gc.LineTo(P(inner, baseHalf));
                gc.EndFigure(true);
            }
        }
        var brush = new SolidColorBrush(Palette.ClaudeAccent);
        ctx.DrawGeometry(brush, null, g);
        ctx.DrawEllipse(brush, null, c, r * 0.24, r * 0.24);
    }

    private static void DrawCodex(DrawingContext ctx, Point c, double r)
    {
        var pen = new Pen(new SolidColorBrush(Palette.CodexAccent), Math.Max(1, r * 0.22), lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
        var hex = new StreamGeometry();
        using (var gc = hex.Open())
        {
            for (int i = 0; i < 6; i++)
            {
                double a = i * Math.PI / 3 - Math.PI / 2;
                var p = new Point(c.X + r * Math.Cos(a), c.Y + r * Math.Sin(a));
                if (i == 0) gc.BeginFigure(p, false); else gc.LineTo(p);
            }
            gc.EndFigure(true);
        }
        ctx.DrawGeometry(null, pen, hex);
        double w = r * 2, x0 = c.X - r, y0 = c.Y - r;
        ctx.DrawLine(pen, new Point(x0 + w * 0.30, y0 + w * 0.36), new Point(x0 + w * 0.46, y0 + w * 0.50));
        ctx.DrawLine(pen, new Point(x0 + w * 0.46, y0 + w * 0.50), new Point(x0 + w * 0.30, y0 + w * 0.64));
        ctx.DrawLine(pen, new Point(x0 + w * 0.52, y0 + w * 0.66), new Point(x0 + w * 0.70, y0 + w * 0.66));
    }
}

internal sealed class UsageBar : Panel
{
    private readonly Border _fill = new() { HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(2), Height = 4 };
    private double _fraction = -1;

    public UsageBar()
    {
        Height = 4;
        VerticalAlignment = VerticalAlignment.Center;
        Children.Add(new Border { Background = Palette.Track, CornerRadius = new CornerRadius(2), Height = 4 });
        Children.Add(_fill);
    }

    public void Set(double? fraction, UsageLevel level)
    {
        _fraction = fraction ?? -1;
        _fill.Background = new SolidColorBrush(Palette.Usage(level));
        _fill.IsVisible = fraction is not null;
        InvalidateArrange();
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        if (_fraction >= 0 && finalSize.Width > 0)
        {
            _fill.Width = Math.Max(3, finalSize.Width * _fraction);
            // Animate later changes only; the first width appears immediately.
            _fill.Transitions ??= [new DoubleTransition { Property = WidthProperty, Duration = TimeSpan.FromMilliseconds(500), Easing = new SpringEase(0.5, 0.85, 0.7) }];
        }
        return base.ArrangeOverride(finalSize);
    }
}

internal static class Icons
{
    private static Geometry Gear()
    {
        var g = new StreamGeometry();
        using var gc = g.Open();
        for (int i = 0; i < 8; i++)
        {
            double a = i * Math.PI / 4;
            gc.BeginFigure(new Point(8 + 4.2 * Math.Cos(a), 8 + 4.2 * Math.Sin(a)), false);
            gc.LineTo(new Point(8 + 6.2 * Math.Cos(a), 8 + 6.2 * Math.Sin(a)));
            gc.EndFigure(false);
        }
        gc.BeginFigure(new Point(12.2, 8), false);
        gc.ArcTo(new Point(3.8, 8), new Size(4.2, 4.2), 0, false, SweepDirection.Clockwise);
        gc.ArcTo(new Point(12.2, 8), new Size(4.2, 4.2), 0, false, SweepDirection.Clockwise);
        gc.EndFigure(true);
        return g;
    }

    public static Geometry Refresh => Geometry.Parse("M 13 8 A 5 5 0 1 1 11.5 4.5 M 11.8 1.6 L 11.8 4.8 L 8.6 4.8");
    public static Geometry Pin => Geometry.Parse("M 6 2 L 10 2 L 10 6.5 L 12 9 L 4 9 L 6 6.5 Z M 8 9 L 8 14");
    public static Geometry Settings => Gear();
    public static Geometry Power => Geometry.Parse("M 8 2 L 8 8 M 4.7 4.3 A 5 5 0 1 0 11.3 4.3");
}
