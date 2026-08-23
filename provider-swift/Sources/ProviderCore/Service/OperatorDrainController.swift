import Foundation

/// Runs one operator-requested provider drain.
///
/// Manual administration is deliberately safer than auto-update. If paid work
/// does not finish before the deadline, the provider reopens admission and the
/// CLI action fails. It never force-cancels inference on the operator's behalf.
public struct OperatorDrainController: Sendable {
    public enum Outcome: Sendable, Equatable {
        case unavailable
        case busy
        case drained
        case timedOut
    }

    public struct Dependencies: Sendable {
        /// Claims the lifecycle gate and closes admission. Returns false if an
        /// update, shutdown, or another operator drain already owns it.
        public var begin: @Sendable () async -> Bool
        /// Waits for coordinator and local inference to finish.
        public var waitForDrain: @Sendable (Duration) async -> Bool
        /// Reopens admission after a timeout.
        public var resume: @Sendable () async -> Void
        /// Closes the coordinator only after the in-flight count reaches zero.
        public var finishShutdown: @Sendable () async -> Void

        public init(
            begin: @escaping @Sendable () async -> Bool,
            waitForDrain: @escaping @Sendable (Duration) async -> Bool,
            resume: @escaping @Sendable () async -> Void,
            finishShutdown: @escaping @Sendable () async -> Void
        ) {
            self.begin = begin
            self.waitForDrain = waitForDrain
            self.resume = resume
            self.finishShutdown = finishShutdown
        }
    }

    private let dependencies: Dependencies
    private let timeout: Duration

    public init(dependencies: Dependencies, timeout: Duration) {
        self.dependencies = dependencies
        self.timeout = timeout
    }

    public func run() async -> Outcome {
        guard await dependencies.begin() else { return .busy }
        guard await dependencies.waitForDrain(timeout) else {
            await dependencies.resume()
            return .timedOut
        }
        await dependencies.finishShutdown()
        return .drained
    }
}
