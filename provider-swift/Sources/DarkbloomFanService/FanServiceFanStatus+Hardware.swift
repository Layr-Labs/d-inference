import DarkbloomFanCore
import DarkbloomFanProtocol

extension FanServiceFanStatus {
    /// Shared hardware projection for helper status and read-only CLI diagnosis.
    public init(reading: FanReading) {
        let mode: String
        switch reading.mode {
        case .automatic: mode = "auto"
        case .manual: mode = "manual"
        case .system: mode = "system"
        case .unknown(let raw): mode = "unknown(\(raw))"
        }
        self.init(
            index: reading.capability.index,
            actualRPM: reading.actualRPM,
            targetRPM: reading.targetRPM,
            minimumRPM: reading.minimumRPM,
            maximumRPM: reading.maximumRPM,
            mode: mode
        )
    }
}
