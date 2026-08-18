import Foundation

/// Coordinator-reported reputation counters for one provider machine.
///
/// Every field remains optional so an omitted measurement is presented as
/// not reported rather than as zero. This snapshot contains no earnings or
/// locally derived success-rate data.
struct MyMacReputationSnapshot: Equatable, Sendable {
    var score: Double?
    var totalJobs: Int?
    var successfulJobs: Int?
    var failedJobs: Int?
    var recordedUptimeSeconds: Int64?
    var averageResponseTimeMilliseconds: Int64?
    var challengesPassed: Int?
    var challengesFailed: Int?
}
