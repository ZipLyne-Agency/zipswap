import Darwin

/// PID plus kernel birth time avoids confusing a reused PID with a live
/// continuation. The implementation is C-only so a forked watchdog can use it.
public struct ProcessIdentity: Equatable {
    public let pid: Int32
    public let startTime: Double
    public static func capture(_ pid: Int32) -> ProcessIdentity? {
        var mib = (Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_PID), pid)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = withUnsafeMutablePointer(to: &mib) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 4) { sysctl($0, 4, &info, &size, nil, 0) }
        }
        guard result == 0, size > 0, info.kp_proc.p_stat != SZOMB else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: pid, startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
    public static func matches(pid: Int32, startTime: Double) -> Bool {
        capture(pid)?.startTime == startTime
    }
}
