import CryptoKit
import Foundation

func checkRoundTrips() throws {
    let (a, b) = try fixturePair()
    let setup = try fixtureContext(request: nil, type: .keyConfirmation)
    let payload = Data("fixture-only-content".utf8)
    for type in [ClusterRecordType.keyConfirmation, .loadAgreement, .loadedReady] {
        let context = try fixtureContext(request: nil, type: type)
        let record = try a.seal(payload, context: context)
        try require(record.count == 24 + payload.count + 16, "wire overhead")
        try require(try b.open(record, expecting: context) == payload, "setup round trip")
    }
    try require(try a.open(b.seal(payload, context: setup), expecting: setup) == payload, "reverse direction")
    for type in [ClusterRecordType.requestAgreement, .residualHeader, .residualPayload, .targetToken,
                 .generationDecision, .acknowledgement, .requestRetired] {
        let context = try fixtureContext(type: type)
        try require(try b.open(a.seal(payload, context: context), expecting: context) == payload, "request round trip")
    }
    let otherRequest = UUID(uuidString: "455d20ee-906c-4c20-9976-d120f6466092")!
    let other = try fixtureContext(request: otherRequest)
    let record = try a.seal(payload, context: other)
    let header = try ClusterRecordHeader.decode(Data(record.prefix(24)), maximumPlaintextBytes: 1024)
    try require(header.sequence == 10, "new request reset nonce sequence")
    try require(header.nonceBytes.count == 12, "nonce width")
    try require(try b.open(record, expecting: other) == payload, "fresh request round trip")
    try require(a.status.sealedRecords == 11 && b.status.openedRecords == 11, "successful accounting")
    try require(a.status.sealedPlaintextBytes == UInt64(payload.count * 11), "byte accounting")
}

func checkTamperAndFraming() throws {
    let context = try fixtureContext()
    let payload = Data(repeating: 63, count: 64)
    // Header, ciphertext and tag tampering each get an independent channel.
    for offset in [0, 4, 5, 6, 7, 8, 15, 16, 19, 20, 23, 24, 50, 87, 88, 103] {
        let (sender, receiver) = try fixturePair()
        var record = try sender.seal(payload, context: context)
        record[offset] ^= 1
        try refuses { _ = try receiver.open(record, expecting: context) }
        try requirePoisoned(receiver)
    }
    for count in [0, 1, 23, 24, 39, 40, 41, 64, 103] {
        let (sender, receiver) = try fixturePair()
        let record = try sender.seal(payload, context: context)
        try refuses { _ = try receiver.open(Data(record.prefix(count)), expecting: context) }
        try requirePoisoned(receiver)
    }
    for suffix in [Data([0]), Data(repeating: 0, count: 104)] {
        let (sender, receiver) = try fixturePair()
        let record = try sender.seal(payload, context: context)
        try refuses { _ = try receiver.open(record + suffix, expecting: context) }
        try requirePoisoned(receiver)
    }
    let (sender, _) = try fixturePair()
    let record = try sender.seal(payload, context: context)
    try require(try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(
        fromPrefix: Data(record.prefix(24)), maximumPlaintextBytes: 1024) == record.count, "bounded prefix")
    var huge = Data(record.prefix(24))
    huge.replaceSubrange(16..<20, with: [255, 255, 255, 255])
    try refuses(.recordTooLarge) {
        _ = try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: huge, maximumPlaintextBytes: 1024)
    }
    for offset in [4, 5, 6, 7] {
        var unknown = Data(record.prefix(24)); unknown[offset] = 255
        try refuses(.malformedRecord) {
            _ = try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: unknown, maximumPlaintextBytes: 1024)
        }
    }
    var zero = Data(record.prefix(24)); zero.replaceSubrange(16..<20, with: [0, 0, 0, 0])
    try refuses(.recordTooLarge) {
        _ = try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: zero, maximumPlaintextBytes: 1024)
    }
    try refuses(.malformedRecord) {
        _ = try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: record, maximumPlaintextBytes: 1024)
    }
    let maximum = ClusterRecordHeader(direction: 0, type: .residualPayload, sequence: 0,
        plaintextBytes: ClusterRecordLimits.hardMaximumPlaintextBytes).encoded
    try require(try ClusterAuthenticatedRecordChannel.boundedRecordByteCount(fromPrefix: maximum,
        maximumPlaintextBytes: ClusterRecordLimits.hardMaximumPlaintextBytes) == 16 * 1024 * 1024 + 40,
        "maximum framing cap")
}

func checkBindingAndContext() throws {
    let context = try fixtureContext(), payload = Data([5, 6, 7])
    let epoch = UUID(uuidString: "58aa0d53-7e21-4fa8-93f1-67b7b4d502ef")!
    let variants = [try fixtureBinding(epoch: epoch), try fixtureBinding(plan: 18), try fixtureBinding(membership: 32)]
    for binding in variants {
        let sender = try fixtureChannel(0), receiver = try fixtureChannel(1, binding: binding)
        let record = try sender.seal(payload, context: context)
        try refuses(.authenticationFailed) { _ = try receiver.open(record, expecting: context) }
        try requirePoisoned(receiver)
    }
    do {
        let sender = try fixtureChannel(0), receiver = try fixtureChannel(1, key: 92)
        try refuses(.authenticationFailed) { _ = try receiver.open(sender.seal(payload, context: context), expecting: context) }
        try requirePoisoned(receiver)
    }
    do {
        let sender = try fixtureChannel(0), receiver = try fixtureChannel(0)
        try refuses(.unexpectedRecord) { _ = try receiver.open(sender.seal(payload, context: context), expecting: context) }
        try requirePoisoned(receiver)
    }
    for expected in [try fixtureContext(request: epoch), try fixtureContext(expectation: 48),
                     try fixtureContext(type: .residualHeader)] {
        let (sender, receiver) = try fixturePair()
        try refuses { _ = try receiver.open(sender.seal(payload, context: context), expecting: expected) }
        try requirePoisoned(receiver)
    }
    // Limits are also canonical key/AAD context, not an unauthenticated override.
    let sender = try fixtureChannel(0)
    let receiver = try fixtureChannel(1, limits: fixtureLimits(records: 127))
    try refuses(.authenticationFailed) { _ = try receiver.open(sender.seal(payload, context: context), expecting: context) }
    try requirePoisoned(receiver)
}

func checkReplayAndBudgets() throws {
    let context = try fixtureContext(), payload = Data([1, 2, 3, 4])
    do {
        let (sender, receiver) = try fixturePair()
        let record = try sender.seal(payload, context: context)
        _ = try receiver.open(record, expecting: context)
        try refuses(.sequenceMismatch) { _ = try receiver.open(record, expecting: context) }
        try requirePoisoned(receiver, opened: 1)
    }
    do {
        let (sender, receiver) = try fixturePair()
        _ = try sender.seal(payload, context: context)
        let skipped = try sender.seal(payload, context: context)
        try refuses(.sequenceMismatch) { _ = try receiver.open(skipped, expecting: context) }
        try requirePoisoned(receiver)
    }
    do {
        let limits = try fixtureLimits(bytes: 4, records: 1, total: 4)
        let sender = try fixtureChannel(0, limits: limits), receiver = try fixtureChannel(1, limits: limits)
        _ = try receiver.open(sender.seal(payload, context: context), expecting: context)
        try refuses(.usageLimitReached) { _ = try sender.seal(Data([1]), context: context) }
        try requirePoisoned(sender)
        // A forged next sequence cannot wrap or gain another receive allowance.
        let next = ClusterRecordHeader(direction: 0, type: context.type, sequence: 1, plaintextBytes: 1).encoded
            + Data(repeating: 0, count: 17)
        try refuses(.usageLimitReached) { _ = try receiver.open(next, expecting: context) }
        try requirePoisoned(receiver, opened: 1)
    }
    do {
        let limits = try fixtureLimits(bytes: 4, records: 9, total: 4)
        let sender = try fixtureChannel(0, limits: limits)
        _ = try sender.seal(payload, context: context)
        try refuses(.usageLimitReached) { _ = try sender.seal(Data([1]), context: context) }
        try requirePoisoned(sender)
    }
    for payload in [Data(), Data(repeating: 0, count: 5)] {
        let sender = try fixtureChannel(0, limits: fixtureLimits(bytes: 4))
        try refuses(.recordTooLarge) { _ = try sender.seal(payload, context: context) }
        try requirePoisoned(sender)
    }
    let sender = try fixtureChannel(0)
    sender.invalidate()
    try refuses(.inactive) { _ = try sender.seal(payload, context: context) }
    try requirePoisoned(sender)
}
