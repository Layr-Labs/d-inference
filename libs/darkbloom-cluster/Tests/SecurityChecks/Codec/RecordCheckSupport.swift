import CryptoKit
import Foundation

enum RecordFixtureError: Error { case failed(String) }
func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw RecordFixtureError.failed(label) }
}
func refuses(_ expected: ClusterRecordError? = nil, _ body: () throws -> Void) throws {
    do { try body() } catch let error as ClusterRecordError {
        if let expected { try require(error == expected, "wrong closed refusal") }
        return
    }
    throw RecordFixtureError.failed("missing closed refusal")
}
let fixtureEpoch = UUID(uuidString: "9633081f-8116-4a15-8ae3-39ee1451f3ed")!
let fixtureRequest = UUID(uuidString: "d811512b-125f-4dfc-a41a-3ea1f6a86c93")!
let fixtureZeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
func fixtureKey(_ byte: UInt8 = 91) -> SymmetricKey {
    SymmetricKey(data: Data(repeating: byte, count: 32))
}
func fixtureBinding(epoch: UUID = fixtureEpoch, plan: UInt8 = 17,
                    membership: UInt8 = 31) throws -> ClusterRecordBinding {
    try .init(epoch: epoch, planSHA256: Data(repeating: plan, count: 32),
        membershipTranscriptSHA256: Data(repeating: membership, count: 32))
}
func fixtureContext(request: UUID? = fixtureRequest, type: ClusterRecordType = .residualPayload,
                    expectation: UInt8 = 47) throws -> ClusterRecordContext {
    try .init(requestID: request, type: type, expectationSHA256: Data(repeating: expectation, count: 32))
}
func fixtureLimits(bytes: Int = 1024, records: UInt64 = 128,
                   total: UInt64 = 65_536) throws -> ClusterRecordLimits {
    try .init(maximumPlaintextBytes: bytes, maximumRecordsPerDirection: records,
        maximumCumulativePlaintextBytesPerDirection: total)
}
func fixtureChannel(_ rank: Int, key: UInt8 = 91, binding: ClusterRecordBinding? = nil,
                    limits: ClusterRecordLimits? = nil) throws -> ClusterAuthenticatedRecordChannel {
    try .init(sessionKey: fixtureKey(key), binding: binding ?? fixtureBinding(),
        localRank: rank, limits: limits ?? fixtureLimits())
}
func fixturePair() throws -> (ClusterAuthenticatedRecordChannel, ClusterAuthenticatedRecordChannel) {
    (try fixtureChannel(0), try fixtureChannel(1))
}
func requirePoisoned(_ channel: ClusterAuthenticatedRecordChannel, opened: UInt64 = 0) throws {
    try require(!channel.status.active && !channel.status.operationInFlight, "channel did not finish poisoned")
    try require(channel.status.openedRecords == opened, "refusal advanced receive state")
    if opened == 0 { try require(channel.status.openedPlaintextBytes == 0, "refusal charged received plaintext") }
    try refuses(.inactive) { _ = try channel.seal(Data([1]), context: fixtureContext()) }
}
