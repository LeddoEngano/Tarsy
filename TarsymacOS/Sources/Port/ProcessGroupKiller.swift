import Foundation

/// Kills entire process groups instead of just the parent process.
/// Fixes Bug #8: Ctrl+C only kills shell, not child dev server processes.
enum ProcessGroupKiller {

    /// Kill entire process group for a given PID.
    /// 1. SIGTERM to process group (graceful shutdown)
    /// 2. Wait for grace period
    /// 3. SIGKILL if still alive (force kill)
    static func killProcessGroup(pid: pid_t, gracePeriod: TimeInterval = 2.0) async {
        let pgid = getpgid(pid)
        let target: pid_t = (pgid > 0) ? -pgid : pid

        // SIGTERM to entire group
        kill(target, SIGTERM)

        // Wait for grace period
        try? await Task.sleep(nanoseconds: UInt64(gracePeriod * 1_000_000_000))

        // SIGKILL if process still alive
        if kill(pid, 0) == 0 {
            kill(target, SIGKILL)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Kill a specific process by PID (graceful then force)
    static func killProcess(pid: pid_t, gracePeriod: TimeInterval = 1.0) async {
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: UInt64(gracePeriod * 1_000_000_000))
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Get the process group ID for a PID. Returns nil if the process doesn't exist.
    static func getProcessGroupId(for pid: pid_t) -> pid_t? {
        let pgid = getpgid(pid)
        return pgid > 0 ? pgid : nil
    }
}
