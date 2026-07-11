import Foundation

public struct FanProviderActivityReader {
    public static let defaultMaximumStateAge: TimeInterval = 15

    public let stateFile: URL
    public let maximumStateAge: TimeInterval

    public init(
        stateFile: URL = InferenceActivityFile.path(),
        maximumStateAge: TimeInterval = defaultMaximumStateAge
    ) {
        self.stateFile = stateFile
        self.maximumStateAge = maximumStateAge
    }

    public func inferenceActive(
        now: Double = Date().timeIntervalSince1970
    ) -> Bool {
        Self.inferenceActive(
            state: InferenceActivityFile.read(from: stateFile),
            now: now,
            maximumStateAge: maximumStateAge
        )
    }

    static func inferenceActive(
        state: InferenceActivityState?,
        now: Double,
        maximumStateAge: TimeInterval = defaultMaximumStateAge,
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> Bool {
        guard let state,
              state.activeRequestCount > 0,
              state.writtenAt <= now + 1,
              now - state.writtenAt <= maximumStateAge,
              let recordedIdentity = state.processIdentity,
              readIdentity(recordedIdentity.pid) == recordedIdentity else {
            return false
        }
        return true
    }
}
