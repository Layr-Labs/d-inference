/// PanicHook -- POSIX signal handler that leaves a fixed local crash marker
/// before re-raising.
///
/// macOS Swift has no built-in crash/`panic` hook. The closest equivalents:
///   * NSSetUncaughtExceptionHandler -- catches Objective-C exceptions
///     (rare in pure Swift, but the bridges call into them).
///   * `signal(2)` on SIGSEGV / SIGBUS / SIGILL / SIGABRT -- catches
///     hard crashes from misaligned memory, traps, and `fatalError`.
///
/// Both paths converge on `recordPanic(...)`, whose production telemetry calls
/// are privacy-disabled no-ops, then re-raise with the default handler so
/// launchd / CrashReporter sees the real exit status.

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
                    // Objective-C exception reasons can embed request values
                    // (for example invalid media URLs or template arguments).
                    // Keep only the fixed category; the call stack retains the
                    // actionable code location without persisting plaintext.
                    message: "uncaught Objective-C exception",
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

    // Production client telemetry is disabled; both calls are no-ops except
    // that shutdown removes an exact legacy queue left by an older build.
    TelemetryOverflowQueue.shared.push(event)
    TelemetryClient.shared.shutdownSync()

    // Best-effort fixed marker on stderr so the launchd log captures it next to
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
