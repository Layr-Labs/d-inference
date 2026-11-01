import Foundation

extension DaemonState {
    /// Local observation only. No request identities, contents, or credentials.
    public struct ModelActivity: Codable, Sendable, Equatable {
        public var model: String
        public var state: String
        public var running: UInt32
        public var waiting: UInt32

        public init(model: String, state: String, running: UInt32, waiting: UInt32) {
            self.model = model
            self.state = state
            self.running = running
            self.waiting = waiting
        }
    }
}
