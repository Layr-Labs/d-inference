import Foundation

struct FanProviderActivityReader {
    static let defaultMaximumStateAge: TimeInterval = 15

    let stateFile: URL
    let maximumStateAge: TimeInterval

    init(
        stateFile: URL,
        maximumStateAge: TimeInterval = defaultMaximumStateAge
    ) {
        self.stateFile = stateFile
        self.maximumStateAge = maximumStateAge
    }

    func inferenceActive(
        now: Double = Date().timeIntervalSince1970
    ) -> Bool {
        Self.inferenceActive(
            state: DaemonStateFile.read(from: stateFile),
            now: now,
            maximumStateAge: maximumStateAge
        )
    }

    static func inferenceActive(
        state: DaemonState?,
        now: Double,
        maximumStateAge: TimeInterval = defaultMaximumStateAge,
        processAlive: (Int32) -> Bool = daemonProcessAlive,
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> Bool {
        guard let state,
              state.inferenceActive,
              !state.isStale(now: now, maxAge: maximumStateAge),
              WatchdogProbe.recordBelongsToLiveProcess(
                state,
                processAlive: processAlive,
                readIdentity: readIdentity
              ) else {
            return false
        }
        return true
    }
}
