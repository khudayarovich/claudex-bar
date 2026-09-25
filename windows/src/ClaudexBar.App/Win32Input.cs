using System.Runtime.InteropServices;
using Avalonia;

namespace ClaudexBar.App;

internal static partial class Win32Input
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public int X;
        public int Y;
    }

    [LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int vKey);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out Point32 point);

    public static bool LeftButtonDown() => OperatingSystem.IsWindows() && (GetAsyncKeyState(0x01) & 0x8000) != 0;

    public static PixelPoint? CursorPosition() =>
        OperatingSystem.IsWindows() && GetCursorPos(out var p) ? new PixelPoint(p.X, p.Y) : null;
}

internal static partial class Win32Motion
{
    private const uint SpiGetClientAreaAnimation = 0x1042;

    [LibraryImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SystemParametersInfo(uint action, uint param, [MarshalAs(UnmanagedType.Bool)] out bool value, uint winIni);

    /// <summary>False when the user turned off "Animation effects" (Windows' reduce-motion setting).</summary>
    public static bool AnimationsEnabled()
    {
        if (!OperatingSystem.IsWindows()) return true;
        try { return !SystemParametersInfo(SpiGetClientAreaAnimation, 0, out var on, 0) || on; }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return true; }
    }
}
