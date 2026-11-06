import Foundation
import ProviderCore

// Red skeleton: status says nothing yet about how this Mac serves.
extension Status {
    static func servingLines(state: DaemonState, liveEndpoint: LocalEndpoint.Info?, route: LocalSettings.Route?,
                             accountKeySaved: () -> Bool, now: Date = Date(),
                             timeZone: TimeZone = .current) -> [String] { [] }

    static func meFirstLines(_ snapshot: MeFirstSnapshot, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        []
    }

    static func requestsLine(route: LocalSettings.Route?, accountKeySaved: Bool) -> String { "" }

    static func ago(milliseconds: Int64) -> String { "" }

    static func clock(_ milliseconds: Int64, timeZone: TimeZone) -> String { "" }
}
