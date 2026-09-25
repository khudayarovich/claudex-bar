using System.Globalization;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClaudexBar.Core;

namespace ClaudexBar.App;

internal enum IslandMode { Collapsed, Peek, Expanded }

internal sealed record IslandActions(Action<string> ActivateSession, Action OpenSettings, Action Refresh, Action Quit);

/// <summary>Layout constants shared by the window frame and the content, so they can't disagree.</summary>
internal static class Metrics
{
    public const double Band = 30, Center = 36, Ear = 72;
    public const double CollapsedShoulder = 6, CollapsedBottom = 10;
    public const double PeekShoulder = 8, PeekBottom = 16, PeekLine = 30, PeekMax = 480;
    public const double ExpShoulder = 14, ExpBottom = 22, ExpWidth = 560;
    public const double TopGap = 8, UsageChrome = 26, UsageRow = 18, SectionGap = 10, Row = 34, Empty = 44, Footer = 26, BottomPad = 12;
    public const double Margin = 18;

    public static double CollapsedWidth => Center + 2 * Ear + 2 * CollapsedShoulder;

    public static double ExpandedHeight(int usageRows, int sessionRows, bool more) =>
        Band + TopGap + UsageChrome + usageRows * UsageRow + SectionGap
        + (sessionRows == 0 ? Empty : (sessionRows + (more ? 1 : 0)) * Row) + SectionGap + Footer + BottomPad;
}

internal sealed class IslandWindow : Window
{
    private readonly IslandViewModel _vm;
    private readonly AppSettings _settings;
    private readonly IslandActions _actions;
    private readonly bool _reduceMotion;
    private readonly Border _shadow = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
    private readonly IslandShape _island = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
    private readonly Grid _band = new();
    private readonly EarView _left, _right;
    private readonly Panel _content = new();
    private readonly PeekQueue _queue = new();
    private IslandMode _mode = IslandMode.Collapsed;
    private bool _pinned, _hovering, _suppressHover, _hiddenForFullScreen;
    private PeekEvent? _peek;
    private int _transition;
    private DispatcherTimer? _hoverTimer, _peekTimer, _pinTimer;

    public IslandMode Mode => _mode;
    public bool Pinned => _pinned;
    public Action<PeekEvent>? PeekSound { get; set; }

    private readonly bool _animate;

    public IslandWindow(IslandViewModel vm, AppSettings settings, IslandActions actions, bool reduceMotion, bool snapshot = false)
    {
        _animate = !snapshot;
        _vm = vm;
        _settings = settings;
        _actions = actions;
        _reduceMotion = reduceMotion || !Win32Motion.AnimationsEnabled();
        Title = "ClaudexBar";
        SystemDecorations = SystemDecorations.None;
        Topmost = true;
        ShowInTaskbar = false;
        CanResize = false;
        ShowActivated = false;
        TransparencyLevelHint = [WindowTransparencyLevel.Transparent];
        Background = Brushes.Transparent;
        RequestedThemeVariant = Avalonia.Styling.ThemeVariant.Dark;

        _left = new EarView(Provider.Claude, left: true);
        _right = new EarView(Provider.Codex, left: false);
        _band.ColumnDefinitions = new ColumnDefinitions("*,Auto,*");
        _band.Height = Metrics.Band;
        _band.Children.Add(_left);
        var center = new Border { Width = Metrics.Center };
        Grid.SetColumn(center, 1);
        _band.Children.Add(center);
        Grid.SetColumn(_right, 2);
        _band.Children.Add(_right);

        var stack = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(_band, Dock.Top);
        stack.Children.Add(_band);
        stack.Children.Add(_content);
        _island.Child = stack;
        _island.Cursor = new Cursor(StandardCursorType.Hand);

        _shadow.BoxShadow = new BoxShadows(new BoxShadow { OffsetY = 6, Blur = 18, Color = Color.FromArgb(150, 0, 0, 0) });
        _shadow.Background = Brushes.Black;
        _shadow.Opacity = 0;

        var root = new Panel { Children = { _shadow, _island } };
        Content = root;

        _island.PointerEntered += (_, _) => HoverChanged(true);
        _island.PointerExited += (_, _) => HoverChanged(false);
        _band.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(_band).Properties.IsLeftButtonPressed) TogglePin();
        };
        Opened += (_, _) =>
        {
            Win32.MakeOverlay(TryGetPlatformHandle()?.Handle ?? 0);
            ApplyLayout(IslandMode.Collapsed, animate: false);
        };
        _vm.Changed += () => Dispatcher.UIThread.Post(Refresh);
        Refresh();
        ApplyLayout(IslandMode.Collapsed, animate: false);
    }

    // MARK: - Data

    public void Refresh()
    {
        _left.Update(_vm.Claude, _mode == IslandMode.Expanded, _settings.ShowUsageRing, _reduceMotion);
        _right.Update(_vm.Codex, _mode == IslandMode.Expanded, _settings.ShowUsageRing, _reduceMotion);
        if (_mode == IslandMode.Expanded)
        {
            _content.Children.Clear();
            _content.Children.Add(BuildExpanded());
            var target = TargetSize(IslandMode.Expanded);
            if (Math.Abs(target.Height - _island.Height) > 0.5) ApplyLayout(IslandMode.Expanded, animate: true);
        }
    }

    // MARK: - Layout

    private Size TargetSize(IslandMode mode) => mode switch
    {
        IslandMode.Collapsed => new Size(Metrics.CollapsedWidth, Metrics.Band),
        IslandMode.Peek => new Size(Math.Clamp(PeekWidth(), Metrics.CollapsedWidth, Metrics.PeekMax), Metrics.Band + Metrics.PeekLine),
        _ => new Size(Metrics.ExpWidth,
            Metrics.ExpandedHeight(_vm.UsageRowCount, _vm.Rows.Count, _vm.HiddenRows > 0)),
    };

    private double PeekWidth()
    {
        if (_peek is null) return Metrics.CollapsedWidth;
        double Measure(string text, FontWeight weight) =>
            new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                new Typeface(FontFamily.Default, FontStyle.Normal, weight), 12, Brushes.White).Width;
        return Math.Ceiling(Measure(_peek.Title, FontWeight.SemiBold) + Measure(_peek.Detail, FontWeight.Normal) + 14 + 11 + 4 * 8 + 32 + 12);
    }

    private void ApplyLayout(IslandMode mode, bool animate)
    {
        animate &= _animate;
        var size = TargetSize(mode);
        double margin = mode == IslandMode.Collapsed ? 0 : Metrics.Margin;
        var canvas = new Size(size.Width + 2 * margin, size.Height + margin);
        int id = ++_transition;
        bool growing = canvas.Width > Width || canvas.Height > Height || double.IsNaN(Width);
        if (growing || !animate) SetCanvas(canvas);

        var (response, damping, duration) = mode == IslandMode.Collapsed ? (0.32, 0.9, 0.45) : (0.42, 0.74, 0.6);
        var easing = _reduceMotion ? (Avalonia.Animation.Easings.Easing)new Avalonia.Animation.Easings.CubicEaseInOut() : new SpringEase(response, damping, duration);
        var span = TimeSpan.FromSeconds(_reduceMotion ? 0.2 : duration);
        Transitions? T(params AvaloniaProperty[] props) => animate
            ? [.. props.Select(p => (ITransition)new DoubleTransition { Property = p, Duration = span, Easing = easing })]
            : null;
        _island.Transitions = T(WidthProperty, HeightProperty, IslandShape.ShoulderProperty, IslandShape.BottomProperty);
        _shadow.Transitions = T(WidthProperty, HeightProperty, OpacityProperty);

        var (shoulder, bottom) = mode switch
        {
            IslandMode.Collapsed => (Metrics.CollapsedShoulder, Metrics.CollapsedBottom),
            IslandMode.Peek => (Metrics.PeekShoulder, Metrics.PeekBottom),
            _ => (Metrics.ExpShoulder, Metrics.ExpBottom),
        };
        _island.Width = size.Width;
        _island.Height = size.Height;
        _island.Shoulder = shoulder;
        _island.Bottom = bottom;
        _island.Padding = new Thickness(shoulder, 0);
        _shadow.Width = Math.Max(0, size.Width - 2 * shoulder);
        _shadow.Height = size.Height;
        _shadow.CornerRadius = new CornerRadius(0, 0, bottom, bottom);
        _shadow.Opacity = mode == IslandMode.Collapsed ? 0 : 1;

        if (!growing && animate)
        {
            DispatcherTimer.RunOnce(() => { if (id == _transition) SetCanvas(canvas); }, span + TimeSpan.FromMilliseconds(30));
        }
    }

    private void SetCanvas(Size canvas)
    {
        Width = canvas.Width;
        Height = canvas.Height;
        if (!_animate) return;   // snapshots: size only
        var screen = Screens?.Primary ?? Screens?.All.FirstOrDefault();
        if (screen is null) return;
        double scale = screen.Scaling;
        int w = (int)Math.Ceiling(canvas.Width * scale);
        int inset = (int)(24 * scale);
        int x = _settings.Position switch
        {
            IslandPosition.Left => screen.WorkingArea.X + inset,
            IslandPosition.Right => screen.WorkingArea.Right - w - inset,
            _ => screen.Bounds.X + (screen.Bounds.Width - w) / 2,
        };
        Position = new PixelPoint(x, screen.WorkingArea.Y);
    }

    public void Reposition() => SetCanvas(new Size(Width, Height));

    // MARK: - Transitions

    public void Present(IslandMode mode, bool pinned = false)
    {
        _mode = mode;
        _pinned = pinned;
        _content.Children.Clear();
        if (mode == IslandMode.Peek && _peek is not null) _content.Children.Add(BuildPeekLine(_peek));
        if (mode == IslandMode.Expanded)
        {
            _queue.Clear();
            _peekTimer?.Stop();
            _peek = null;
            _content.Children.Add(BuildExpanded());
            _actions.Refresh();
        }
        FadeIn(_content);
        _left.Update(_vm.Claude, mode == IslandMode.Expanded, _settings.ShowUsageRing, _reduceMotion);
        _right.Update(_vm.Codex, mode == IslandMode.Expanded, _settings.ShowUsageRing, _reduceMotion);
        ApplyLayout(mode, animate: true);
        if (pinned) StartPinWatch(); else _pinTimer?.Stop();
    }

    private void FadeIn(Control c)
    {
        if (_reduceMotion) return;
        c.Opacity = 0;
        c.Transitions = [new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(200), Delay = TimeSpan.FromMilliseconds(70) }];
        Dispatcher.UIThread.Post(() => c.Opacity = 1, DispatcherPriority.Background);
    }

    public void TogglePin()
    {
        if (_mode == IslandMode.Expanded && _pinned) Collapse(suppressHover: true);
        else Present(IslandMode.Expanded, pinned: true);
    }

    public void Collapse(bool suppressHover = false)
    {
        if (suppressHover) _suppressHover = true;
        if (_mode == IslandMode.Collapsed) return;
        _peek = null;
        _queue.Clear();
        _peekTimer?.Stop();
        Present(IslandMode.Collapsed);
    }

    /// <summary>While pinned, a click anywhere outside the island collapses it.</summary>
    private void StartPinWatch()
    {
        _pinTimer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, (_, _) =>
        {
            if (!_pinned || !Win32Input.LeftButtonDown()) return;
            var cursor = Win32Input.CursorPosition();
            if (cursor is null) return;
            var topLeft = Position;
            double scale = Screens.Primary?.Scaling ?? 1;
            var rect = new PixelRect(topLeft, new PixelSize((int)(Width * scale), (int)(Height * scale)));
            if (!rect.Contains(cursor.Value)) Collapse();
        });
        _pinTimer.Start();
    }

    // MARK: - Hover

    private void HoverChanged(bool inside)
    {
        if (inside == _hovering) return;
        _hovering = inside;
        _hoverTimer?.Stop();
        if (inside)
        {
            if (_suppressHover) return;
            if (_mode == IslandMode.Collapsed) _hoverTimer = After(150, () => { if (_hovering && _mode == IslandMode.Collapsed) Present(IslandMode.Expanded); });
            else if (_mode == IslandMode.Peek)
            {
                _queue.Hold(DateTimeOffset.UtcNow);
                _peekTimer?.Stop();
                _hoverTimer = After(600, () => { if (_hovering && _mode == IslandMode.Peek) Present(IslandMode.Expanded); });
            }
        }
        else
        {
            _suppressHover = false;
            if (_mode == IslandMode.Expanded && !_pinned)
                _hoverTimer = After(350, () => { if (!_hovering && _mode == IslandMode.Expanded && !_pinned) Present(IslandMode.Collapsed); });
            else if (_mode == IslandMode.Peek)
            {
                _queue.Release(DateTimeOffset.UtcNow);
                SchedulePeekTimer();
            }
        }
    }

    private static DispatcherTimer After(int ms, Action action)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
        t.Tick += (_, _) => { t.Stop(); action(); };
        t.Start();
        return t;
    }

    // MARK: - Peeks

    public void Enqueue(IEnumerable<PeekEvent> events)
    {
        if (_hiddenForFullScreen || _mode == IslandMode.Expanded) return;
        foreach (var e in events) Handle(_queue.Enqueue(e, DateTimeOffset.UtcNow));
    }

    private void Handle(PeekQueue.Effect effect)
    {
        switch (effect.Kind)
        {
            case PeekQueue.EffectKind.Show when effect.Event is { } e:
                bool isNew = _peek?.Id != e.Id;
                _peek = e;
                Present(IslandMode.Peek);
                if (isNew) PeekSound?.Invoke(e);
                SchedulePeekTimer();
                break;
            case PeekQueue.EffectKind.Hide:
                _peek = null;
                if (_mode == IslandMode.Peek) Present(IslandMode.Collapsed);
                break;
        }
    }

    private void SchedulePeekTimer()
    {
        _peekTimer?.Stop();
        if (_queue.Deadline is not { } d) return;
        var delay = d - DateTimeOffset.UtcNow;
        _peekTimer = After((int)Math.Max(50, delay.TotalMilliseconds), () => Handle(_queue.Expire(DateTimeOffset.UtcNow)));
    }

    public void SetHiddenForFullScreen(bool hidden)
    {
        if (hidden == _hiddenForFullScreen) return;
        _hiddenForFullScreen = hidden;
        if (hidden)
        {
            Collapse();
            Hide();
        }
        else Show();
    }

    // MARK: - Content

    private Control BuildPeekLine(PeekEvent e)
    {
        var light = new TrafficLight(single: true);
        light.Apply(e.Lamp switch
        {
            LampColor.Red => new LampTriple(LampMode.Blinking, LampMode.Off, LampMode.Off),
            LampColor.Yellow => new LampTriple(LampMode.Off, LampMode.Steady, LampMode.Off),
            _ => new LampTriple(LampMode.Off, LampMode.Off, LampMode.Breathing),
        }, _reduceMotion);
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8, Height = Metrics.PeekLine, Margin = new Thickness(16, 0),
            Children =
            {
                light,
                new Glyph(e.Provider, 11, ring: false) { VerticalAlignment = VerticalAlignment.Center },
                Text(e.Title, 12, Palette.Primary, FontWeight.SemiBold),
                Text(e.Detail, 12, Palette.Secondary),
            },
        };
        row.PointerPressed += (_, _) =>
        {
            if (e.SessionId is { } id) { _actions.ActivateSession(id); Collapse(suppressHover: true); }
            else TogglePin();
        };
        return row;
    }

    private static TextBlock Text(string text, double size, IBrush brush, FontWeight weight = FontWeight.Normal) => new()
    {
        Text = text, FontSize = size, Foreground = brush, FontWeight = weight,
        VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1,
    };

    private Control BuildExpanded()
    {
        var panel = new StackPanel { Margin = new Thickness(12, 0) };
        panel.Children.Add(new Border { Height = Metrics.TopGap });
        int usageRows = _vm.UsageRowCount;
        var cards = new Grid { ColumnDefinitions = new ColumnDefinitions("*,18,*"), Height = Metrics.UsageChrome + usageRows * Metrics.UsageRow, Margin = new Thickness(6, 0) };
        var c1 = UsageCard(_vm.Claude, usageRows);
        var c2 = UsageCard(_vm.Codex, usageRows);
        Grid.SetColumn(c2, 2);
        cards.Children.Add(c1);
        cards.Children.Add(c2);
        panel.Children.Add(cards);
        panel.Children.Add(Separator());
        if (_vm.Rows.Count == 0)
        {
            panel.Children.Add(new StackPanel
            {
                Height = Metrics.Empty, VerticalAlignment = VerticalAlignment.Center, Spacing = 2,
                Children =
                {
                    new TextBlock { Text = "No active sessions", FontSize = 12, Foreground = Palette.Secondary, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) },
                    new TextBlock { Text = "Claude Code and Codex sessions appear here while they run", FontSize = 10, Foreground = Palette.Tertiary, HorizontalAlignment = HorizontalAlignment.Center },
                },
            });
        }
        else
        {
            foreach (var row in _vm.Rows) panel.Children.Add(SessionRow(row));
            if (_vm.HiddenRows > 0)
                panel.Children.Add(new TextBlock { Text = $"+{_vm.HiddenRows} more", FontSize = 10.5, Foreground = Palette.Tertiary, Height = Metrics.Row, Padding = new Thickness(10, 10, 0, 0) });
        }
        panel.Children.Add(Separator());
        panel.Children.Add(Footer());
        return panel;
    }

    private static Control Separator() => new Rectangle
    {
        Height = 1, Fill = Palette.Separator, Margin = new Thickness(0, (Metrics.SectionGap - 1) / 2),
    };

    private Control UsageCard(ProviderSummary s, int rows)
    {
        var card = new StackPanel();
        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6, Height = Metrics.UsageChrome - 6, Margin = new Thickness(0, 0, 0, 6),
            Children =
            {
                new Glyph(s.Provider, 11, ring: false) { VerticalAlignment = VerticalAlignment.Center },
                Text(s.Provider.DisplayName(), 11, Palette.Primary, FontWeight.SemiBold),
            },
        };
        if (s.Plan is { } plan) header.Children.Add(Text(plan, 10, Palette.Tertiary));
        if (s.UsageNote is { } note && s.Usage.Count > 0) header.Children.Add(Text(note, 9.5, Palette.Tertiary));
        card.Children.Add(header);
        if (s.Usage.Count == 0)
            card.Children.Add(new TextBlock { Text = s.UsageNote ?? "No usage data", FontSize = 10.5, Foreground = Palette.Tertiary, Height = Metrics.UsageRow });
        foreach (var r in s.Usage.Take(rows))
        {
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("46,*,40,62"), Height = Metrics.UsageRow };
            var bar = new UsageBar { Margin = new Thickness(0, 0, 8, 0) };
            bar.Set(r.Fraction, r.Level);
            var pct = Text(r.PercentText, 10.5, Palette.Primary, FontWeight.SemiBold);
            pct.HorizontalAlignment = HorizontalAlignment.Right;
            var reset = Text(r.ResetText ?? "", 9.5, Palette.Tertiary);
            reset.Margin = new Thickness(8, 0, 0, 0);
            grid.Children.Add(Text(r.Label, 10.5, Palette.Secondary, FontWeight.Medium));
            Grid.SetColumn(bar, 1);
            grid.Children.Add(bar);
            Grid.SetColumn(pct, 2);
            grid.Children.Add(pct);
            Grid.SetColumn(reset, 3);
            grid.Children.Add(reset);
            card.Children.Add(grid);
        }
        return card;
    }

    private Control SessionRow(SessionRowModel r)
    {
        var light = new TrafficLight(single: true);
        light.Apply(r.Lamps, _reduceMotion);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*,Auto"), Height = Metrics.Row };
        var titles = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(9, 0, 8, 0), Spacing = 1,
            Children =
            {
                Text(r.Title, 12, Palette.Primary, FontWeight.SemiBold),
                Text(r.Activity, 10.5, r.IsAttention ? new SolidColorBrush(Palette.Red) : Palette.Secondary),
            },
        };
        var right = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center, Spacing = 2,
            Children =
            {
                new TextBlock { Text = Formatters.Elapsed(r.Since, DateTimeOffset.UtcNow), FontSize = 10.5, Foreground = Palette.Secondary, FontWeight = FontWeight.Medium, HorizontalAlignment = HorizontalAlignment.Right },
                new TextBlock { Text = r.Badge, FontSize = 9, Foreground = Palette.Tertiary, HorizontalAlignment = HorizontalAlignment.Right },
            },
        };
        var glyph = new Glyph(r.Provider, 11, ring: false) { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(9, 0, 0, 0) };
        grid.Children.Add(light);
        Grid.SetColumn(glyph, 1);
        grid.Children.Add(glyph);
        Grid.SetColumn(titles, 2);
        grid.Children.Add(titles);
        Grid.SetColumn(right, 3);
        grid.Children.Add(right);
        var button = new Button
        {
            Content = grid, Background = Brushes.Transparent, Padding = new Thickness(10, 0), CornerRadius = new CornerRadius(9),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        button.Click += (_, _) => { _actions.ActivateSession(r.Id); Collapse(suppressHover: true); };
        return button;
    }

    private Control Footer()
    {
        var updated = _vm.LastUpdate is { } d
            ? (Formatters.Elapsed(d, DateTimeOffset.UtcNow) is var e && e == "now" ? "Updated just now" : $"Updated {e} ago")
            : "Starting…";
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Height = Metrics.Footer, Margin = new Thickness(6, 0) };
        grid.Children.Add(Text(updated, 10, Palette.Tertiary));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(IconButton(Icons.Refresh, "Refresh now", _actions.Refresh));
        buttons.Children.Add(IconButton(Icons.Pin, _pinned ? "Unpin" : "Keep open", TogglePin));
        buttons.Children.Add(IconButton(Icons.Settings, "Settings", _actions.OpenSettings));
        buttons.Children.Add(IconButton(Icons.Power, "Quit ClaudexBar", _actions.Quit));
        Grid.SetColumn(buttons, 1);
        grid.Children.Add(buttons);
        return grid;
    }

    private static Button IconButton(Geometry icon, string tip, Action action)
    {
        var b = new Button
        {
            Content = new Avalonia.Controls.Shapes.Path { Data = icon, Stroke = Palette.Secondary, StrokeThickness = 1.4, StrokeLineCap = PenLineCap.Round, Width = 16, Height = 16, Stretch = Stretch.None },
            Background = Brushes.Transparent, Padding = new Thickness(2), Width = 22, Height = 22,
        };
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => action();
        return b;
    }
}

/// <summary>One side of the band: glyph at the outer edge, traffic light toward the center.</summary>
internal sealed class EarView : Grid
{
    private readonly Glyph _glyph;
    private readonly TrafficLight _light = new();
    private readonly StackPanel _labels = new() { VerticalAlignment = VerticalAlignment.Center, Spacing = -1 };
    private readonly TextBlock _name = new() { FontSize = 12, FontWeight = FontWeight.SemiBold, Foreground = Palette.Primary };
    private readonly TextBlock _plan = new() { FontSize = 9.5, FontWeight = FontWeight.Medium, Foreground = Palette.Secondary };
    private readonly bool _isLeft;

    public EarView(Provider provider, bool left)
    {
        _isLeft = left;
        _glyph = new Glyph(provider, 19, ring: true) { VerticalAlignment = VerticalAlignment.Center };
        _name.Text = provider.DisplayName();
        _labels.Children.Add(_name);
        _labels.Children.Add(_plan);
        _labels.HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        var start = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Right,
        };
        if (left) { start.Children.Add(_glyph); start.Children.Add(_labels); }
        else { start.Children.Add(_labels); start.Children.Add(_glyph); }
        _light.HorizontalAlignment = left ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        Children.Add(start);
        Children.Add(_light);
        Margin = left ? new Thickness(7, 0, 5, 0) : new Thickness(5, 0, 7, 0);
    }

    public void Update(ProviderSummary s, bool expanded, bool showRing, bool reduceMotion)
    {
        _light.Apply(s.Lamps, reduceMotion);
        _glyph.HasRing = showRing;
        _glyph.Level = s.RingLevel;
        _glyph.Fraction = s.Ring ?? -1;
        _glyph.InvalidateVisual();
        if (expanded && !_labels.IsVisible && !reduceMotion)
        {
            // Fade the labels in once the band has mostly spread out.
            _labels.Transitions = [new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(200), Delay = TimeSpan.FromMilliseconds(160) }];
            _labels.Opacity = 0;
            Avalonia.Threading.Dispatcher.UIThread.Post(() => _labels.Opacity = 1, Avalonia.Threading.DispatcherPriority.Background);
        }
        _labels.IsVisible = expanded;
        _plan.Text = s.Plan ?? "";
        _plan.IsVisible = s.Plan is not null;
        Margin = _isLeft ? new Thickness(expanded ? 14 : 7, 0, expanded ? 12 : 5, 0) : new Thickness(expanded ? 12 : 5, 0, expanded ? 14 : 7, 0);
    }
}
