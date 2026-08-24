import Foundation

/// Canonical rule for deciding whether an on-disk daemon record still
/// describes a live provider process. A PID alone is insufficient because the
/// kernel can reuse it after the provider exits. Legacy records without a
/// kernel start identity therefore fail closed.
public enum DaemonStateRuntimeTruth {
    public static func belongsToLiveProcess(
        _ state: DaemonState,
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> Bool {
        guard let recorded = state.processIdentity else { return false }
        guard recorded.pid == state.pid else {
            return false
        }
        return readIdentity(state.pid) == recorded
    }

    public static func isFreshAndLive(
        _ state: DaemonState,
        now: Double = Date().timeIntervalSince1970,
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> Bool {
        belongsToLiveProcess(
            state,
            readIdentity: readIdentity
        ) && !state.isStale(now: now)
    }
}
