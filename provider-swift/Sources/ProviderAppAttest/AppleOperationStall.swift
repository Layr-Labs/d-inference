import Foundation

/// A DeviceCheck call whose callback never arrives keeps `AppleOperationGate`
/// held, so every later Apple operation answers `busy` until the process
/// exits. `ready` replies report such a stall as `operation_stalled_seconds`.
public enum AppleOperationStall {
    /// Far above the 25 s callback deadline and every coordinator exchange
    /// timeout: only a callback Apple never delivered stays held this long.
    public static let threshold: TimeInterval = 15 * 60
    /// Upper bound accepted by the coordinator; longer stalls report this.
    public static let maxReportedSeconds = 86_400

    /// Seconds to report, or nil while the gate is idle or held briefly.
    public static func reportedSeconds(heldSince: Date?, now: Date) -> Int? {
        guard let heldSince else { return nil }
        let held = now.timeIntervalSince(heldSince)
        guard held.isFinite, held > threshold else { return nil }
        return Int(min(held, Double(maxReportedSeconds)))
    }
}
