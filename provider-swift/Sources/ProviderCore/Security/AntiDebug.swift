/// Anti-debug protections: PT_DENY_ATTACH and debugger detection.

import Darwin
import Foundation
import os

@_silgen_name("ptrace")
private func ptrace_raw(_ request: CInt, _ pid: pid_t, _ addr: UnsafeMutableRawPointer?, _ data: CInt) -> CInt

private let antiDebugLogger = Logger(subsystem: "dev.darkbloom.provider", category: "security")

// MARK: - PT_DENY_ATTACH

/// Prevent debugger attachment using ptrace(PT_DENY_ATTACH).
///
/// On macOS, this syscall tells the kernel to deny any future ptrace requests
/// against this process. Even root cannot override this while SIP is enabled.
/// Combined with Hardened Runtime (no get-task-allow entitlement), this makes
/// the process's memory unreadable.
///
/// Must be called early in process startup, before any sensitive data is loaded.
public func denyDebuggerAttachment() throws {
    let PT_DENY_ATTACH: CInt = 31
    let result = ptrace_raw(PT_DENY_ATTACH, 0, nil, 0)
    if result == 0 {
        antiDebugLogger.info("Anti-debug: PT_DENY_ATTACH enabled -- debugger attachment blocked")
    } else {
        let err = String(cString: strerror(errno))
        throw SecurityError.ptDenyAttachFailed(
            "refusing to continue without anti-debug protection: \(err)"
        )
    }
}

// MARK: - Core Dump Disabling

/// Disable core dumps for this process.
///
/// Core dumps can contain plaintext prompts, model weights, and private keys.
/// Setting RLIMIT_CORE to zero prevents the kernel from writing core files
/// even if the process crashes. This complements PT_DENY_ATTACH and Hardened
/// Runtime to ensure no crash artifact leaks sensitive data.
public func disableCoreDumps() throws {
    var zero = rlimit(rlim_cur: 0, rlim_max: 0)
    let ret = setrlimit(RLIMIT_CORE, &zero)
    if ret == 0 {
        antiDebugLogger.info("Core dumps disabled (RLIMIT_CORE = 0)")
    } else {
        let err = String(cString: strerror(errno))
        throw SecurityError.coreDumpDisableFailed(err)
    }
}

// MARK: - Anti-Debug Detection

/// Check if a debugger is currently attached to this process.
///
/// Uses `sysctl` to query the kernel for the P_TRACED flag on our own
/// process. This is a belt-and-suspenders check alongside PT_DENY_ATTACH --
/// if PT_DENY_ATTACH was somehow bypassed (e.g., SIP disabled), this
/// detects the active attachment.
public func checkDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

    let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard result == 0 else {
        antiDebugLogger.warning("Anti-debug: sysctl failed, cannot check P_TRACED")
        return false
    }

    let flags = info.kp_proc.p_flag
    let isTraced = (flags & P_TRACED) != 0

    if isTraced {
        antiDebugLogger.error("Anti-debug: P_TRACED flag detected -- debugger is attached")
    }
    return isTraced
}
