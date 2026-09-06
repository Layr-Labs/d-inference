import Foundation

/// Canonical trust rule for `local.json`.
///
/// The record contains a bearer token and a destination for plaintext prompts,
/// so a PID existence check is not sufficient: after PID reuse it could
/// authorize sending both to an unrelated process. Legacy records remain
/// decodable for compatibility but fail this trust check.
public enum LocalEndpointRuntimeTruth {
    public static func belongsToLiveProcess(
        _ info: LocalEndpointInfo,
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> Bool {
        guard let recorded = info.processIdentity,
              recorded.pid == info.pid
        else {
            return false
        }
        return readIdentity(info.pid) == recorded
    }
}
