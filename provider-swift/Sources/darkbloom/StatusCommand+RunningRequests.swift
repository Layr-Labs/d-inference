import Foundation
import ProviderCore

extension Status {
    static let creditsLine = "Credits post when an answer finishes."

    /// The answers this Mac (or its pair) is writing now, under the serving
    /// block. Not listed yet.
    static func runningRequestLines(state: DaemonState, now: Double) -> [String] {
        []
    }

    /// `status --json`: the running provider's answers in progress. Not
    /// listed yet.
    static func statusJSON(state: DaemonState?, alive: Bool, now: Double, heartbeatIntervalSecs: UInt64,
                           clusterPart: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": 1])
    }
}
