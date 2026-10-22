import CryptoKit
import Foundation

func checkConfigurationRefusals() throws {
    for count in [0, 16, 24, 31, 33, 64] {
        try refuses(.invalidKeySize) {
            _ = try ClusterAuthenticatedRecordChannel(sessionKey: SymmetricKey(data: Data(repeating: 0, count: count)),
                binding: fixtureBinding(), localRank: 0, limits: fixtureLimits())
        }
    }
    for rank in [-1, 2, Int.max] {
        try refuses(.invalidConfiguration) { _ = try fixtureChannel(rank) }
    }
    for bytes in [Int.min, -1, 0, ClusterRecordLimits.hardMaximumPlaintextBytes + 1, Int.max] {
        try refuses(.invalidConfiguration) { _ = try fixtureLimits(bytes: bytes) }
    }
    for count in [UInt64(0), ClusterRecordLimits.hardMaximumRecords + 1, UInt64.max] {
        try refuses(.invalidConfiguration) { _ = try fixtureLimits(records: count) }
    }
    for bytes in [UInt64(0), UInt64(1023), ClusterRecordLimits.hardMaximumCumulativePlaintextBytes + 1, UInt64.max] {
        try refuses(.invalidConfiguration) { _ = try fixtureLimits(total: bytes) }
    }
    try refuses(.invalidContext) { _ = try fixtureBinding(epoch: fixtureZeroUUID) }
    for bytes in [0, 31, 33] {
        try refuses(.invalidContext) {
            _ = try ClusterRecordBinding(epoch: fixtureEpoch, planSHA256: Data(repeating: 0, count: bytes),
                membershipTranscriptSHA256: Data(repeating: 0, count: 32))
        }
        try refuses(.invalidContext) {
            _ = try ClusterRecordBinding(epoch: fixtureEpoch, planSHA256: Data(repeating: 0, count: 32),
                membershipTranscriptSHA256: Data(repeating: 0, count: bytes))
        }
        try refuses(.invalidContext) {
            _ = try ClusterRecordContext(requestID: fixtureRequest, type: .residualPayload,
                expectationSHA256: Data(repeating: 0, count: bytes))
        }
    }
    for type in [ClusterRecordType.keyConfirmation, .loadAgreement, .loadedReady] {
        try refuses(.invalidContext) { _ = try fixtureContext(type: type) }
    }
    for type in [ClusterRecordType.requestAgreement, .residualHeader, .residualPayload, .targetToken,
                 .generationDecision, .acknowledgement, .requestRetired] {
        try refuses(.invalidContext) { _ = try fixtureContext(request: nil, type: type) }
    }
    try refuses(.invalidContext) { _ = try fixtureContext(request: fixtureZeroUUID) }
}

func fixtureState() throws -> ClusterRecordState {
    try .init(sessionKey: fixtureKey(), binding: fixtureBinding(), localRank: 0, limits: fixtureLimits())
}
func startWork(_ state: ClusterRecordState, outbound: Bool) throws -> ClusterRecordState.Work {
    let context = try fixtureContext()
    if outbound { return try state.beginSeal(byteCount: 4, context: context) }
    let header = ClusterRecordHeader(direction: 1, type: context.type, sequence: 0, plaintextBytes: 4)
    return try state.beginOpen(header: header, recordByteCount: 44, context: context)
}

/// Exercises the exact lock/ticket helper used around CryptoKit. No runtime
/// callback/test hook is added, and this does not claim to preempt CryptoKit.
func checkConcurrentAndInvalidation() throws {
    for first in [false, true] {
        for second in [false, true] {
            let state = try fixtureState()
            let held = try startWork(state, outbound: first)
            try refuses(.concurrentOperation) { _ = try startWork(state, outbound: second) }
            try require(!state.status.active && state.status.operationInFlight,
                "racing refusal lost original operation hold")
            try refuses(.inactive) { try state.finish(held) }
            try require(!state.status.operationInFlight && state.status.sealedRecords == 0
                && state.status.openedRecords == 0, "failed overlap published or retained operation")
        }
        let state = try fixtureState()
        let held = try startWork(state, outbound: first)
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue(label: "record-fixture-invalidation").async {
            state.invalidate()
            completion.signal()
        }
        try require(completion.wait(timeout: .now() + 1) == .success,
            "invalidation blocked on outstanding crypto ticket")
        try require(!state.status.active && state.status.operationInFlight, "invalidation hold status")
        try refuses(.inactive) { try state.finish(held) }
        try require(state.status.openedRecords == 0 && state.status.sealedRecords == 0
            && !state.status.operationInFlight, "invalidation allowed publication")
    }
}

func checkCanonicalAndCounterBoundaries() throws {
    let a = try fixtureState(), b = try fixtureState()
    let one = try a.beginSeal(byteCount: 4, context: fixtureContext())
    let two = try b.beginSeal(byteCount: 4, context: fixtureContext())
    try require(one.authenticatedData == two.authenticatedData, "canonical AAD is unstable")
    try require(one.header.encoded.count == 24 && one.header.nonceBytes.count == 12, "fixed framing")
    // This helper receives only the count and context, never inference bytes.
    try require(one.authenticatedData.count < 512, "AAD unexpectedly grows with payload")
    try a.finish(one); a.fail(operation: nil)
    try require(a.status.sealedRecords == 1 && !a.status.active, "post-publication invalidate changed accounting")
    try refuses(.inactive) { try a.finish(one) }
    b.fail(operation: two.id)
    try require(!b.status.operationInFlight && b.status.sealedRecords == 0, "failed crypto cleanup")

    let (sender, receiver) = try fixturePair()
    let context = try fixtureContext(), payload = Data([1, 2, 3, 4])
    let first = try sender.seal(payload, context: context)
    let second = try sender.seal(payload, context: context)
    let h0 = try ClusterRecordHeader.decode(Data(first.prefix(24)), maximumPlaintextBytes: 1024)
    let h1 = try ClusterRecordHeader.decode(Data(second.prefix(24)), maximumPlaintextBytes: 1024)
    try require(h0.sequence == 0 && h1.sequence == 1 && h0.nonceBytes != h1.nonceBytes,
        "repeated plaintext reused nonce")
    _ = try receiver.open(first, expecting: context)
    _ = try receiver.open(second, expecting: context)
    var exhausted = second
    exhausted.replaceSubrange(8..<16, with: Array(repeating: UInt8(255), count: 8))
    try refuses(.sequenceMismatch) { _ = try receiver.open(exhausted, expecting: context) }
    try requirePoisoned(receiver, opened: 2)
}
