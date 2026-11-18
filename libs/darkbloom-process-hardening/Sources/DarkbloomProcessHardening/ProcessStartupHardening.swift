import Foundation

/// The first statement of every Darkbloom executable's `main`: removes the
/// exception handlers the process was started with, before any key, prompt or
/// model exists, and records whether any was left. Code that is about to hold
/// keys, prompts or answers calls `requireClean()` (or `exitUnlessClean(as:)`):
/// `darkbloom` (serving and every other non-diagnostic command), the enclave
/// helper and the cluster worker refuse; the planner and the root fan helper,
/// which hold neither, only record.
public enum ProcessStartupHardening {
    public struct Outcome: Equatable, Sendable {
        /// The handlers present at launch; nil when they could not be read.
        public let inherited: InheritedExceptionPorts.Handlers?
        /// The handlers present after the removal; nil when they could not be read.
        public let remaining: InheritedExceptionPorts.Handlers?
        public let removalAccepted: Bool

        public init(inherited: InheritedExceptionPorts.Handlers?, remaining: InheritedExceptionPorts.Handlers?,
                    removalAccepted: Bool) {
            self.inherited = inherited
            self.remaining = remaining
            self.removalAccepted = removalAccepted
        }

        /// Removed and confirmed: no handler this process did not choose is left.
        public var isClean: Bool { removalAccepted && remaining?.isEmpty == true }
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// `applyAtLaunch()` never ran in this process.
        case notApplied
        /// The removal was refused or a handler is still present.
        case handlersRemain

        public var description: String {
            switch self {
            case .notApplied:
                "process startup hardening did not run; this process will not serve"
            case .handlersRemain:
                "process startup hardening could not be applied; this process will not serve"
            }
        }
    }

    /// Removes the inherited handlers once and records the outcome; later
    /// calls return the first outcome.
    @discardableResult
    public static func applyAtLaunch() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if let recorded { return recorded }
        let inherited = InheritedExceptionPorts.current()
        let accepted = InheritedExceptionPorts.removeAll()
        let outcome = Outcome(inherited: inherited, remaining: InheritedExceptionPorts.current(),
                              removalAccepted: accepted)
        recorded = outcome
        return outcome
    }

    /// The recorded outcome; nil when `applyAtLaunch()` has not run.
    public static var outcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Throws unless `applyAtLaunch()` ran and left no handler.
    public static func requireClean() throws {
        guard let outcome else { throw Refusal.notApplied }
        guard outcome.isClean else { throw Refusal.handlersRemain }
    }

    /// `requireClean()` for an executable that has no diagnostics to offer:
    /// prints `<executable>: <refusal>` to standard error and exits 1.
    public static func exitUnlessClean(as executable: String) {
        do {
            try requireClean()
        } catch {
            FileHandle.standardError.write(Data("\(executable): \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    /// The only argument that makes an executable print its startup record
    /// (`report`) and exit, before it does anything else.
    public static let reportArgument = "--report-startup-hardening"

    /// Tests: `1` makes an executable print its startup record and then wait
    /// for a signal, before it does anything else, whatever its arguments, so
    /// a test can end it right after startup and see whether any exception
    /// handler is still told about it.
    public static let holdEnvironmentKey = "DARKBLOOM_STARTUP_HARDENING_HOLD"

    /// Prints the startup record and exits 0 when `arguments` (without the
    /// executable path) is exactly `reportArgument`; prints it and waits for a
    /// signal when `holdEnvironmentKey` is `1`; otherwise returns.
    public static func reportIfRequested(_ arguments: [String] = Array(CommandLine.arguments.dropFirst()),
                                         environment: [String: String] = ProcessInfo.processInfo.environment) {
        if arguments == [reportArgument] {
            FileHandle.standardOutput.write(Data((report() + "\n").utf8))
            exit(0)
        }
        guard environment[holdEnvironmentKey] == "1" else { return }
        FileHandle.standardError.write(Data(
            "\(ProcessInfo.processInfo.processName): \(holdEnvironmentKey)=1 (a test setting): holding after startup\n".utf8))
        FileHandle.standardOutput.write(Data((report() + "\n").utf8))
        while true { pause() }
    }

    /// One JSON line: whether the removal ran, whether it left the process
    /// clean, and the masks found at launch and now. Keys are sorted;
    /// `abort-after-startup.c` and the worker's `run.sh` match on that order.
    public static func report() -> String {
        let recorded = outcome
        let now = recorded?.remaining ?? InheritedExceptionPorts.current()
        var fields: [String: Any] = [
            "applied": recorded != nil,
            "clean": recorded?.isClean ?? false,
        ]
        if let inherited = recorded?.inherited {
            fields["inherited_task"] = Int(inherited.task)
            fields["inherited_thread"] = Int(inherited.thread)
        }
        if let now {
            fields["remaining_task"] = Int(now.task)
            fields["remaining_thread"] = Int(now.thread)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: Outcome?
}
