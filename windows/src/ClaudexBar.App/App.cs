using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;
using ClaudexBar.Core;

namespace ClaudexBar.App;

internal sealed class App : Application
{
    public static LaunchOptions Options { get; set; } = new([]);

    private readonly IslandViewModel _vm = new();
    private AppSettings _settings = new();
    private IStatusFeed? _feed;
    private IslandWindow? _island;
    private SettingsWindow? _settingsWindow;
    private TrayIcon? _tray;
    private DispatcherTimer? _tick, _fullScreen;
    private LampTriple _trayLamps = new(LampMode.Dim, LampMode.Dim, LampMode.Dim);

    public override void Initialize()
    {
        Styles.Add(new FluentTheme());
        RequestedThemeVariant = ThemeVariant.Dark;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime desktop)
        {
            base.OnFrameworkInitializationCompleted();
            return;
        }
        desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;

        if (Options.SnapshotDir is { } dir)
        {
            Dispatcher.UIThread.Post(() =>
            {
                SnapshotRenderer.Run(dir);
                desktop.Shutdown();
            });
            base.OnFrameworkInitializationCompleted();
            return;
        }

        _settings = AppSettings.Load();
        _vm.Policy = new LampPolicy(TimeSpan.FromMinutes(_settings.FreshMinutes));
        var actions = new IslandActions(
            ActivateSession: id => Win32.Activate(_vm.Session(id)),
            OpenSettings: OpenSettings,
            Refresh: () => _feed?.RefreshNow(),
            Quit: () => desktop.Shutdown());
        _island = new IslandWindow(_vm, _settings, actions, Options.ReduceMotion)
        {
            PeekSound = e =>
            {
                if (_settings.Sound && e.Kind == PeekKind.Attention) Win32.Beep();
            },
        };
        _vm.Peek += events => Dispatcher.UIThread.Post(() => _island.Enqueue(events.Where(Allowed)));
        _vm.Changed += () => Dispatcher.UIThread.Post(UpdateTray);

        _feed = Options.Demo ? new DemoFeed(Options.DemoScenario) : new ClaudexEngine(_settings.ClaudeUsageApi, _settings.CodexUsageApi);
        _feed.SessionsChanged += s => Dispatcher.UIThread.Post(() => _vm.Apply(s));
        _feed.UsageChanged += u => Dispatcher.UIThread.Post(() => _vm.Apply(u));

        CreateTray(desktop);
        _island.Show();
        _feed.Start();

        _tick = new DispatcherTimer(TimeSpan.FromSeconds(30), DispatcherPriority.Background, (_, _) => _vm.Tick());
        _tick.Start();
        _fullScreen = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) =>
            _island.SetHiddenForFullScreen(_settings.HideInFullScreen && Win32.IsFullScreenAppActive()));
        _fullScreen.Start();

        if (Options.Present == "expanded") Dispatcher.UIThread.Post(() => _island.Present(IslandMode.Expanded, pinned: true), DispatcherPriority.Background);
        desktop.Exit += (_, _) => { _feed.Dispose(); _tray?.Dispose(); };
        base.OnFrameworkInitializationCompleted();
    }

    private bool Allowed(PeekEvent e) => e.Kind switch
    {
        PeekKind.Attention => _settings.PeekAttention,
        PeekKind.Finished => _settings.PeekFinished,
        _ => _settings.PeekUsage,
    };

    private void OpenSettings()
    {
        if (_settingsWindow is { IsVisible: true })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_settings, SettingsChanged);
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void SettingsChanged()
    {
        _vm.Policy = new LampPolicy(TimeSpan.FromMinutes(_settings.FreshMinutes));
        _vm.Tick();
        _island?.Refresh();
        _island?.Reposition();
        if (_feed is ClaudexEngine engine) engine.SetUsageApis(_settings.ClaudeUsageApi, _settings.CodexUsageApi);
    }

    // MARK: - Tray

    private void CreateTray(IClassicDesktopStyleApplicationLifetime desktop)
    {
        var menu = new NativeMenu();
        var pin = new NativeMenuItem("Show panel");
        pin.Click += (_, _) => _island?.TogglePin();
        var refresh = new NativeMenuItem("Refresh now");
        refresh.Click += (_, _) => _feed?.RefreshNow();
        var settings = new NativeMenuItem("Settings…");
        settings.Click += (_, _) => OpenSettings();
        var quit = new NativeMenuItem("Quit ClaudexBar");
        quit.Click += (_, _) => desktop.Shutdown();
        menu.Items.Add(pin);
        menu.Items.Add(refresh);
        menu.Items.Add(settings);
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(quit);
        _tray = new TrayIcon { ToolTipText = "ClaudexBar", Menu = menu, Icon = TrayIconRenderer.Render(_trayLamps), IsVisible = true };
        _tray.Clicked += (_, _) => _island?.TogglePin();
        TrayIcon.SetIcons(this, [_tray]);
    }

    /// <summary>The tray icon is a tiny traffic light showing every state present across both agents.</summary>
    private void UpdateTray()
    {
        if (_tray is null) return;
        var c = _vm.Claude.Lamps;
        var x = _vm.Codex.Lamps;
        LampMode Union(LampMode a, LampMode b) => (LampMode)Math.Max((int)a, (int)b);
        var lamps = new LampTriple(Union(c.Red, x.Red), Union(c.Yellow, x.Yellow), Union(c.Green, x.Green));
        if (lamps == _trayLamps) return;
        _trayLamps = lamps;
        _tray.Icon = TrayIconRenderer.Render(lamps);
        var parts = new List<string>();
        foreach (var s in new[] { _vm.Claude, _vm.Codex })
        {
            var n = s.Counts;
            var bits = new List<string>();
            if (n.Attention > 0) bits.Add($"{n.Attention} need you");
            if (n.Working > 0) bits.Add($"{n.Working} working");
            if (n.WaitingFresh + n.WaitingParked > 0) bits.Add($"{n.WaitingFresh + n.WaitingParked} waiting");
            parts.Add($"{s.Provider.DisplayName()}: {(bits.Count == 0 ? "idle" : string.Join(", ", bits))}");
        }
        _tray.ToolTipText = "ClaudexBar — " + string.Join(" · ", parts);
    }
}

internal static class TrayIconRenderer
{
    public static WindowIcon Render(LampTriple lamps)
    {
        const int size = 32;
        var bitmap = new RenderTargetBitmap(new PixelSize(size, size), new Vector(96, 96));
        using (var ctx = bitmap.CreateDrawingContext())
        {
            ctx.DrawRectangle(new SolidColorBrush(Color.FromRgb(0x12, 0x12, 0x12)), new Pen(new SolidColorBrush(Color.FromArgb(90, 255, 255, 255)), 1),
                new RoundedRect(new Rect(1.5, 9.5, 29, 13), 6.5));
            var modes = new[] { (Palette.Red, lamps.Red), (Palette.Yellow, lamps.Yellow), (Palette.Green, lamps.Green) };
            for (int i = 0; i < 3; i++)
            {
                var (color, mode) = modes[i];
                double alpha = mode switch { LampMode.Off => 0.22, LampMode.Dim => 0.5, _ => 1 };
                ctx.DrawEllipse(new SolidColorBrush(color, alpha), null, new Point(7 + i * 9, 16), 3.6, 3.6);
            }
        }
        return new WindowIcon(bitmap);
    }
}
