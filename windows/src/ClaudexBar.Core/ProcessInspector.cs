using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ClaudexBar.Core;

public interface IProcessInspector
{
    bool IsAlive(int pid);
    DateTimeOffset? StartTime(int pid);
    int? Parent(int pid);
    string? ProcessName(int pid);
    /// <summary>Processes that currently have <paramref name="path"/> open (Windows Restart Manager).</summary>
    IReadOnlyList<int> FileHolders(string path);
    IReadOnlyList<int> PidsNamed(string processName);
}

public sealed class LiveProcessInspector : IProcessInspector
{
    public bool IsAlive(int pid)
    {
        if (pid <= 0) return false;
        try
        {
            using var p = Process.GetProcessById(pid);
            try { return !p.HasExited; }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException) { return true; }
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    public DateTimeOffset? StartTime(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return new DateTimeOffset(p.StartTime.ToUniversalTime(), TimeSpan.Zero);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception or NotSupportedException)
        {
            return null;
        }
    }

    public string? ProcessName(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return p.ProcessName;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception) { return null; }
    }

    public IReadOnlyList<int> PidsNamed(string processName)
    {
        var result = new List<int>();
        foreach (var p in Process.GetProcessesByName(processName))
        {
            result.Add(p.Id);
            p.Dispose();
        }
        return result;
    }

    public int? Parent(int pid) => OperatingSystem.IsWindows() ? Win32Processes.Parent(pid) : null;

    public IReadOnlyList<int> FileHolders(string path) =>
        OperatingSystem.IsWindows() ? RestartManager.Holders(path) : [];
}

public static class ProcessAncestry
{
    public static List<int> Chain(int pid, IProcessInspector inspector, int maxDepth = 32)
    {
        var chain = new List<int>();
        int? current = pid;
        while (current is { } p && p > 4 && chain.Count < maxDepth && !chain.Contains(p))
        {
            chain.Add(p);
            current = inspector.Parent(p);
        }
        return chain;
    }
}

internal static class Win32Processes
{
    private const uint Th32csSnapprocess = 0x00000002;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static Dictionary<int, int> _parents = [];
    private static DateTime _takenAt = DateTime.MinValue;
    private static readonly Lock Gate = new();

    public static int? Parent(int pid)
    {
        lock (Gate)
        {
            if (DateTime.UtcNow - _takenAt > TimeSpan.FromSeconds(5) || !_parents.ContainsKey(pid))
            {
                _parents = Snapshot();
                _takenAt = DateTime.UtcNow;
            }
            return _parents.TryGetValue(pid, out var ppid) && ppid > 0 ? ppid : null;
        }
    }

    private static Dictionary<int, int> Snapshot()
    {
        var map = new Dictionary<int, int>();
        var snap = CreateToolhelp32Snapshot(Th32csSnapprocess, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return map;
        try
        {
            var entry = new ProcessEntry32 { dwSize = (uint)Marshal.SizeOf<ProcessEntry32>() };
            if (!Process32FirstW(snap, ref entry)) return map;
            do { map[(int)entry.th32ProcessID] = (int)entry.th32ParentProcessID; }
            while (Process32NextW(snap, ref entry));
        }
        finally { CloseHandle(snap); }
        return map;
    }
}

/// <summary>
/// Windows Restart Manager: lists the processes that have a file open, without opening or
/// locking the file ourselves (the passive equivalent of libproc's fd listing on macOS).
/// </summary>
internal static class RestartManager
{
    private const int ErrorMoreData = 234;
    private const int CchRmMaxAppName = 255;
    private const int CchRmMaxSvcName = 63;

    [StructLayout(LayoutKind.Sequential)]
    private struct RmUniqueProcess
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RmProcessInfo
    {
        public RmUniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CchRmMaxAppName + 1)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CchRmMaxSvcName + 1)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint sessionHandle, int flags, string sessionKey);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint sessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint sessionHandle, uint nFiles, string[] filenames,
        uint nApplications, [In] RmUniqueProcess[]? applications, uint nServices, string[]? serviceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(uint sessionHandle, out uint procInfoNeeded, ref uint procInfo,
        [In, Out] RmProcessInfo[]? affectedApps, ref uint rebootReasons);

    public static IReadOnlyList<int> Holders(string path)
    {
        if (!File.Exists(path)) return [];
        try
        {
            if (RmStartSession(out var handle, 0, Guid.NewGuid().ToString("N")) != 0) return [];
            try
            {
                if (RmRegisterResources(handle, 1, [path], 0, null, 0, null) != 0) return [];
                uint count = 0, reasons = 0;
                int rc = RmGetList(handle, out var needed, ref count, null, ref reasons);
                if (rc == 0) return [];
                if (rc != ErrorMoreData) return [];
                var infos = new RmProcessInfo[needed];
                count = needed;
                if (RmGetList(handle, out _, ref count, infos, ref reasons) != 0) return [];
                return infos.Take((int)count).Select(i => i.Process.dwProcessId).Distinct().ToList();
            }
            finally { RmEndSession(handle); }
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return []; }
    }
}
