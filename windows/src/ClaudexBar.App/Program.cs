using Avalonia;

namespace ClaudexBar.App;

internal sealed record LaunchOptions(string[] Args)
{
    public bool Demo => Args.Contains("--demo") || DemoScenario is not null;
    public string? DemoScenario => Value("--demo-freeze");
    public string? SnapshotDir => Value("--snapshot");
    public string? Present => Value("--present");
    public bool ReduceMotion => Args.Contains("--force-reduce-motion");

    private string? Value(string flag)
    {
        int i = Array.IndexOf(Args, flag);
        return i >= 0 && i + 1 < Args.Length ? Args[i + 1] : null;
    }
}

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        var options = new LaunchOptions(args);
        // One island at a time (snapshots excepted).
        using var mutex = new Mutex(true, "Local\\ClaudexBar.SingleInstance", out bool first);
        if (!first && options.SnapshotDir is null) return 0;
        App.Options = options;
        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args, Avalonia.Controls.ShutdownMode.OnExplicitShutdown);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace();
}
