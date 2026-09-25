using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using ClaudexBar.Core;
using Microsoft.Win32;

namespace ClaudexBar.App;

/// <summary>Windows-only glue. Every entry point is a no-op on other platforms (dev previews on macOS).</summary>
internal static partial class Win32
{
    private const int GwlExstyle = -20;
    private const long WsExToolwindow = 0x00000080;
    private const long WsExNoactivate = 0x08000000;
    private const long WsExTopmost = 0x00000008;
    private const int SwRestore = 9;

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static partial nint GetWindowLongPtr(nint hWnd, int nIndex);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static partial nint SetWindowLongPtr(nint hWnd, int nIndex, nint dwNewLong);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(nint hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(nint hWnd, int nCmdShow);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsIconic(nint hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(int dwProcessId);

    [LibraryImport("shell32.dll")]
    private static partial int SHQueryUserNotificationState(out int state);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool MessageBeep(uint type);

    /// <summary>The system "asterisk" sound.</summary>
    public static void Beep()
    {
        if (OperatingSystem.IsWindows()) MessageBeep(0x40);
    }

    /// <summary>Tool window (no Alt-Tab), never activated by clicks, always on top.</summary>
    public static void MakeOverlay(nint hwnd)
    {
        if (!OperatingSystem.IsWindows() || hwnd == 0) return;
        var ex = (long)GetWindowLongPtr(hwnd, GwlExstyle);
        SetWindowLongPtr(hwnd, GwlExstyle, (nint)(ex | WsExToolwindow | WsExNoactivate | WsExTopmost));
    }

    /// <summary>A full-screen app, game or presentation is in front.</summary>
    public static bool IsFullScreenAppActive()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            // QUNS_BUSY = 2, QUNS_RUNNING_D3D_FULL_SCREEN = 3, QUNS_PRESENTATION_MODE = 4
            return SHQueryUserNotificationState(out var state) == 0 && state is 2 or 3 or 4;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return false; }
    }

    /// <summary>Brings the app that owns a session forward (desktop app by name, else the
    /// first ancestor process with a window: the terminal or editor).</summary>
    public static void Activate(AgentSession? session)
    {
        if (!OperatingSystem.IsWindows() || session is null) return;
        var candidates = new List<int>();
        if (session.AppHint is { } hint) candidates.AddRange(Process.GetProcessesByName(hint).Select(p => p.Id));
        if (session.Pid is { } pid) candidates.AddRange(ProcessAncestry.Chain(pid, new LiveProcessInspector()));
        foreach (var id in candidates)
        {
            try
            {
                using var p = Process.GetProcessById(id);
                var hwnd = p.MainWindowHandle;
                if (hwnd == 0) continue;
                AllowSetForegroundWindow(id);
                if (IsIconic(hwnd)) ShowWindow(hwnd, SwRestore);
                SetForegroundWindow(hwnd);
                return;
            }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException) { }
        }
    }

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool LaunchAtLoginSupported => OperatingSystem.IsWindows();

    public static bool GetLaunchAtLogin() => OperatingSystem.IsWindows() && ReadRun() is not null;

    public static void SetLaunchAtLogin(bool enabled)
    {
        if (!OperatingSystem.IsWindows()) return;
        WriteRun(enabled);
    }

    [SupportedOSPlatform("windows")]
    private static string? ReadRun()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("ClaudexBar") as string;
    }

    [SupportedOSPlatform("windows")]
    private static void WriteRun(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && Environment.ProcessPath is { } exe) key.SetValue("ClaudexBar", $"\"{exe}\"");
        else key.DeleteValue("ClaudexBar", false);
    }
}
