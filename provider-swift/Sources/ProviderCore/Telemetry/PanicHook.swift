/// PanicHook -- POSIX signal handler that captures fatal crashes,
/// flushes any pending telemetry to disk, and emits a structured panic
/// event before re-raising.
///
/// macOS Swift has no built-in crash/`panic` hook. The closest equivalents:
///   * NSSetUncaughtExceptionHandler -- catches Objective-C exceptions
///     (rare in pure Swift, but the bridges call into them).
///   * `signal(2)` on SIGSEGV / SIGBUS / SIGILL / SIGABRT -- catches
///     hard crashes from misaligned memory, traps, and `fatalError`.
///
/// Both paths converge on `recordPanic(...)` which:
///   1. Builds a TelemetryEvent (kind = .panic, severity = .fatal)
///      with `Thread.callStackSymbols` as the stack trace.
///   2. Pushes it to the disk overflow queue synchronously so it
///      survives the impending process exit.
///   3. Calls `TelemetryClient.shared.shutdownSync()` to flush the
///      in-memory buffer to disk too.
///   4. Re-raises the signal with the default handler so launchd /
///      CrashReporter sees the real exit status.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PanicHook {

    private static let installLock = NSLock()
    private nonisolated(unsafe) static var installed: Bool = false

    /// Install signal + uncaught-exception handlers. Idempotent.
    public static func install() {
        installLock.withLock {
            guard !installed else { return }
            installed = true

            // Fatal POSIX signals. We deliberately do NOT install handlers for
            // SIGINT or SIGTERM -- those are graceful shutdowns, not panics.
            let fatal: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE]
            for signo in fatal {
                _ = signal(signo, panicSignalHandler)
            }

            NSSetUncaughtExceptionHandler { exception in
                recordPanic(
                    kind: "uncaught_exception",
                    message: exception.reason ?? exception.name.rawValue,
                    stack: exception.callStackSymbols.joined(separator: "\n")
                )
            }
        }
    }
}

// MARK: - Signal handler

/// C-callable signal handler. Must be `@convention(c)` and only call
/// async-signal-safe functions in principle. We call into Swift telemetry
/// here -- technically unsafe -- but the alternative is a silent crash.
private func panicSignalHandler(_ signo: Int32) {
    let name: String
    switch signo {
    case SIGSEGV: name = "SIGSEGV"
    case SIGBUS:  name = "SIGBUS"
    case SIGILL:  name = "SIGILL"
    case SIGABRT: name = "SIGABRT"
    case SIGFPE:  name = "SIGFPE"
    default:      name = "signal_\(signo)"
    }

    let stack = Thread.callStackSymbols.joined(separator: "\n")
    recordPanic(kind: "signal", message: name, stack: stack)

    // Restore the default handler and re-raise so the process exits with the
    // real status and Apple's CrashReporter still gets to write its report.
    signal(signo, SIG_DFL)
    raise(signo)
}

// MARK: - Recording

private func recordPanic(kind: String, message: String, stack: String) {
    let truncatedStack = String(stack.prefix(8000))

    var event = TelemetryEvent(
        source: .provider,
        severity: .fatal,
        kind: .panic,
        message: "[\(kind)] \(message)"
    )
    event.stack = truncatedStack

    // 1. Push directly to disk -- shared.emit() may queue without flushing.
    TelemetryOverflowQueue.shared.push(event)

    // 2. Flush the in-memory buffer (lands on disk if network is unavailable).
    TelemetryClient.shared.shutdownSync()

    // 3. Best-effort marker on stderr so the launchd log captures it next to
    //    any `darkbloom logs --watch` viewer.
    let line = "\(panicISO8601Now()) FATAL panic kind=\(kind) message=\(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func panicISO8601Now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
