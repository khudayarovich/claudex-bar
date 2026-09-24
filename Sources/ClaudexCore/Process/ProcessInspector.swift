import Darwin
import Foundation

/// Process introspection used for liveness checks, PID-reuse detection, finding the app
/// that owns a terminal session, and detecting which Codex threads are loaded.
public protocol ProcessInspector: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func startTime(_ pid: Int32) -> Date?
    func parent(_ pid: Int32) -> Int32?
    func executablePath(_ pid: Int32) -> String?
    func allPIDs() -> [Int32]
    /// Paths of regular files the process has open, or nil when the fd list can't be read.
    func openVnodePaths(_ pid: Int32) -> [String]?
}

public struct LibprocInspector: ProcessInspector {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    public func startTime(_ pid: Int32) -> Date? {
        guard let info = kinfo(pid) else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    public func parent(_ pid: Int32) -> Int32? {
        guard let info = kinfo(pid) else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    public func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    public func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    public func openVnodePaths(_ pid: Int32) -> [String]? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard used > 0 else { return nil }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size)
            guard r == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}

public enum ProcessAncestry {
    /// Walks parents from `pid` up to launchd (inclusive of `pid`).
    public static func chain(_ pid: Int32, inspector: ProcessInspector, maxDepth: Int = 32) -> [Int32] {
        var out: [Int32] = []
        var current: Int32? = pid
        while let p = current, p > 1, out.count < maxDepth, !out.contains(p) {
            out.append(p)
            current = inspector.parent(p)
        }
        return out
    }

    /// Path of the first ancestor that looks like a GUI app's main executable.
    public static func owningAppBundle(_ pid: Int32, inspector: ProcessInspector) -> String? {
        for p in chain(pid, inspector: inspector) {
            guard let path = inspector.executablePath(p) else { continue }
            guard let range = path.range(of: ".app/Contents/MacOS/") else { continue }
            if path.contains("/Contents/Helpers/") || path.contains("/Contents/Frameworks/")
                || path.contains("Application Support/Claude/claude-code/") { continue }
            return String(path[..<range.lowerBound]) + ".app"
        }
        return nil
    }
}
