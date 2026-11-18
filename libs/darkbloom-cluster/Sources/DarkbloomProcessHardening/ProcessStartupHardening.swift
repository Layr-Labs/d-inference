import Foundation

/// The first statement of every Darkbloom executable's `main`: removes the
/// exception handlers the process was started with, before any key, prompt or
/// model exists, and records whether any was left. Code that is about to hold
/// keys, prompts or answers calls `requireClean()`.
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
                "could not clear the debugging handles this process was started with; it will not serve"
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

    /// The only argument that makes an executable print its startup record
    /// (`report`) and exit, before it does anything else.
    public static let reportArgument = "--report-startup-hardening"

    /// Prints the startup record and exits 0 when `arguments` (without the
    /// executable path) is exactly `reportArgument`; otherwise returns.
    public static func reportIfRequested(_ arguments: [String]) {
        guard arguments == [reportArgument] else { return }
        FileHandle.standardOutput.write(Data((report() + "\n").utf8))
        exit(0)
    }

    /// One JSON line: whether the removal ran, whether it left the process
    /// clean, and the masks found at launch and now.
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
