import Foundation

/// One sender and one receiver over a loopback link, with every fault a check
/// needs set before `run()`. The two ranks' clocks start hours apart: only
/// durations are shared.
final class TransferScenario {
    let artifact: TinyStageArtifact
    let session: QwenStageTransferSession
    var receiverSession: QwenStageTransferSession
    var source: FileByteSource
    var intake: MemoryIntake
    let senderClock = TransferTestClock(1_000_000_000), receiverClock = TransferTestClock(9_000_000_000_000)
    var senderWatch: QwenStageTransferWatch, receiverWatch: QwenStageTransferWatch
    let link = LoopbackLink()
    private(set) var sender: QwenStageTransferSender<FileByteSource>?
    private(set) var receiver: QwenStageTransferReceiver<MemoryIntake>?

    init(_ artifact: TinyStageArtifact, stages: [Int] = [0, 1]) throws {
        self.artifact = artifact
        session = try artifact.session(stages: stages)
        receiverSession = session
        source = FileByteSource(directory: artifact.directory)
        intake = MemoryIntake(plan: session.plan)
        senderWatch = senderClock.watch(); receiverWatch = receiverClock.watch()
    }

    func run() -> LoopbackLink.Outcome {
        let sender = QwenStageTransferSender(session: session, source: source, watch: senderWatch)
        let receiver = QwenStageTransferReceiver(session: receiverSession, intake: intake, watch: receiverWatch)
        self.sender = sender; self.receiver = receiver
        return link.exchange(sender, receiver)
    }

    var isVerified: Bool { receiver?.isVerified ?? false }

    func control(_ phase: QwenStageTransferControl.Phase, _ role: QwenStageTransferRole, _ window: Int, _ bytes: Int,
                 in session: QwenStageTransferSession? = nil) -> [Int32] {
        QwenStageTransferControl.values(session ?? self.session, phase, from: role, window: window, cumulativeBytes: bytes)
    }
}

private let wrongFromSender = "control value from the sending rank differs"
private let wrongFromReceiver = "control value from the receiving rank differs"
private let contentDiffers = "content differs from its pinned SHA-256"

func checkTransferMachines(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    try checkCleanTransfer(artifact, checks)
    try checkWrongBytes(artifact, checks)
    try checkWrongFraming(artifact, checks)
    try checkWrongControlValues(artifact, checks)
    try checkAborts(artifact, checks)
    try checkDeadlines(artifact, checks)
    try checkIntakeAndMisuse(artifact, checks)
}

private func checkCleanTransfer(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    let scenario = try TransferScenario(artifact)
    let plan = scenario.session.plan
    // The scenarios below name pieces and windows by these indices.
    try checks.require("fixture plan: seven tensors in fifteen pieces and six windows",
        plan.tensors.count == 7 && plan.payloadBytes == 508
        && plan.pieces.map(\.byteCount) == [48, 48, 32, 16, 32, 32, 32, 32, 48, 48, 32, 32, 12, 32, 32]
        && plan.windows.map(\.pieces) == [0..<2, 2..<5, 5..<8, 8..<10, 10..<13, 13..<15]
        && plan.windows.map(\.precedingBytes) == [0, 96, 176, 272, 368, 444]
        && plan.tensors.map(\.pieces) == [0..<3, 3..<4, 4..<6, 6..<8, 8..<12, 12..<13, 13..<15]
        && plan.pieces[8...11].map(\.shape) == [[3, 4], [3, 4], [2, 4], [2, 4]] && plan.pieces[3].shape == [4, 2])
    let outcome = scenario.run()
    try checks.require("both ranks finish and the receiver has verified every tensor",
        outcome.sender == nil && outcome.receiver == nil && scenario.isVerified
        && scenario.sender?.isFinished == true && scenario.sender?.servedBytes == 508
        && scenario.receiver?.receivedBytes == 508 && scenario.link.pieceBytesFromSender == 508)
    var fromSender: [LoopbackLink.Message] = [.control(scenario.control(.transferOpen, .sender, 0, 0))]
    var fromReceiver: [LoopbackLink.Message] = [.control(scenario.control(.transferOpen, .receiver, 0, 0))]
    for (index, window) in plan.windows.enumerated() {
        fromSender.append(.control(scenario.control(.windowOpen, .sender, index, window.precedingBytes)))
        fromSender += window.pieces.map { .piece($0) }
        fromReceiver.append(.control(scenario.control(.windowReceived, .receiver, index, window.precedingBytes + window.byteCount)))
    }
    fromSender.append(.control(scenario.control(.senderComplete, .sender, 6, 508)))
    fromReceiver.append(.control(scenario.control(.stageVerified, .receiver, 6, 508)))
    try checks.require("the link carries open, then each window's open, pieces and receipt, then verdict and close",
        scenario.link.fromSender == fromSender && scenario.link.fromReceiver == fromReceiver)
    let assembled = try scenario.receiver?.verifiedIntake().assembled ?? [:]
    try checks.require("every assembled tensor is byte-identical to its stored range",
        assembled.count == 7 && plan.tensors.enumerated().allSatisfy { assembled[$0.offset] == artifact.content[$0.element.sourceName] })

    let stage1 = try TransferScenario(artifact, stages: [1])
    let single = stage1.run()
    try checks.require("one delivered stage transfers only its own tensors",
        single.sender == nil && single.receiver == nil && stage1.isVerified
        && stage1.session.plan.tensors.count == 3 && stage1.link.pieceBytesFromSender == 236
        && stage1.session.plan.tensors.allSatisfy { $0.stageIndex == 1 })

    // The blocking drivers, each fed the other rank's recorded half of the exchange.
    func content(_ piece: QwenStageTransferPlan.Piece) -> Data {
        let bytes = artifact.content[plan.tensors[piece.tensor].sourceName]!
        return bytes.subdata(in: (bytes.startIndex + piece.byteOffset)..<(bytes.startIndex + piece.byteOffset + piece.byteCount))
    }
    let toSender = ScriptedTransport(incoming: fromReceiver, content: content)
    let drivenSender = QwenStageTransferSender(session: scenario.session, source: scenario.source, watch: scenario.senderClock.watch())
    try drivenSender.run(over: toSender)
    let toReceiver = ScriptedTransport(incoming: fromSender, content: content)
    let drivenReceiver = QwenStageTransferReceiver(session: scenario.session, intake: MemoryIntake(plan: plan),
        watch: scenario.receiverClock.watch())
    try drivenReceiver.run(over: toReceiver)
    try checks.require("the blocking drivers make the same calls over a transport",
        drivenSender.isFinished && toSender.sent == fromSender && drivenReceiver.isVerified && toReceiver.sent == fromReceiver)
    let cut = ScriptedTransport(incoming: Array(fromSender.prefix(5)), content: content)
    let stranded = QwenStageTransferReceiver(session: scenario.session, intake: MemoryIntake(plan: plan),
        watch: scenario.receiverClock.watch())
    try checks.refuses("transport failure in the middle of a window", because: "scripted transport has no such piece") {
        try stranded.run(over: cut)
    }
    try checks.refuses("a receiver whose transport failed makes no further call", because: "already failed") {
        _ = try stranded.next()
    }
    try checks.refuses("an unverified receiver gives up nothing it received", because: "has not been verified") {
        _ = try stranded.verifiedIntake()
    }
    // The sender's transport fails where the receipt for window 1 should arrive.
    let silent = ScriptedTransport(incoming: Array(fromReceiver.prefix(2)), content: content)
    let unanswered = QwenStageTransferSender(session: scenario.session, source: scenario.source, watch: scenario.senderClock.watch())
    try checks.refuses("transport failure while the sender waits for a receipt", because: "scripted transport has no control value") {
        try unanswered.run(over: silent)
    }
    try checks.refuses("a sender whose transport failed makes no further call", because: "already failed") {
        _ = try unanswered.next()
    }
}

private func checkWrongBytes(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    // Piece 3 is a whole 16-byte tensor in window 1.
    let flipped = try TransferScenario(artifact)
    flipped.source.flippedPiece = 3
    var outcome = flipped.run()
    try checks.refuses("one flipped bit in a tensor", because: contentDiffers) {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a flipped bit stops the transfer at that window's boundary",
        !flipped.isVerified && outcome.senderText.contains("receiving rank aborted")
        && flipped.link.fromReceiver.last == .control(flipped.control(.receiverAbort, .receiver, 1, 176))
        && flipped.link.pieceBytesFromSender == 176)

    // With hashing still running at every boundary, the verdict is what refuses.
    let late = try TransferScenario(artifact)
    late.source.flippedPiece = 3; late.intake.deferred = true
    outcome = late.run()
    try checks.refuses("one flipped bit found only when the digests are joined", because: contentDiffers) {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a refused stage is told to the sender, which still closes",
        !late.isVerified && outcome.senderText.contains("refused the transferred stage")
        && late.link.fromReceiver.last == .control(late.control(.stageRefused, .receiver, 6, 508))
        && late.link.fromSender.last == .control(late.control(.senderComplete, .sender, 6, 508)))

    // Tensors 2 and 3 have one shape and dtype; each is sent the other's bytes.
    let swapped = try TransferScenario(artifact)
    let a = swapped.session.records[2].source, b = swapped.session.records[3].source
    swapped.source.substitutedOffsets = [a.sourceOffset: b.sourceOffset, a.sourceOffset + 32: b.sourceOffset + 32,
        b.sourceOffset: a.sourceOffset, b.sourceOffset + 32: a.sourceOffset + 32]
    outcome = swapped.run()
    try checks.refuses("two same-shape tensors swapped", because: contentDiffers) {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("swapped tensors are valid stored bytes of the right shape, refused by name",
        !swapped.isVerified && a.layout.shape == b.layout.shape && a.sourceFile == b.sourceFile
        && artifact.content[a.layout.canonicalName] != artifact.content[b.layout.canonicalName])
}

private func checkWrongFraming(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    // The sender's message 6 is piece 3.
    let short = try TransferScenario(artifact)
    short.link.rewriteFromSender = { $0 == 6 ? Array($1.dropLast(4)) : $1 }
    var outcome = short.run()
    try checks.refuses("a message four bytes short", because: "no progress") {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a short message leaves both ranks waiting for the progress limit",
        !short.isVerified && short.link.fromSender[6] == .piece(3) && outcome.senderText.contains("no progress"))

    let extra = try TransferScenario(artifact)
    extra.link.rewriteFromSender = { $0 == 6 ? $1 + $1 : $1 }
    outcome = extra.run()
    try checks.refuses("an extra message after a piece", because: wrongFromSender) {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("bytes nobody asked for are never taken as a tensor", !extra.isVerified)
}

private func checkWrongControlValues(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    let another = try artifact.session(epoch: "f")
    func refusedBySender(_ name: String, at ordinal: Int,
                         _ value: @escaping (TransferScenario) -> [Int32]) throws {
        let scenario = try TransferScenario(artifact)
        scenario.link.rewriteFromReceiver = { $0 == ordinal ? LoopbackLink.bytes(value(scenario)) : $1 }
        let outcome = scenario.run()
        try checks.refuses(name, because: wrongFromReceiver) { if let error = outcome.sender { throw error } }
        try checks.require(name + ": the sender does not finish", scenario.sender?.isFinished == false)
    }
    func refusedByReceiver(_ name: String, at ordinal: Int,
                           _ value: @escaping (TransferScenario) -> [Int32]) throws {
        let scenario = try TransferScenario(artifact)
        scenario.link.rewriteFromSender = { $0 == ordinal ? LoopbackLink.bytes(value(scenario)) : $1 }
        let outcome = scenario.run()
        try checks.refuses(name, because: wrongFromSender) { if let error = outcome.receiver { throw error } }
        try checks.require(name + ": nothing is verified", !scenario.isVerified)
    }
    // The receiver's message 0 is its open value, 1...6 its window receipts, 7 its verdict.
    try refusedBySender("receipt for another window", at: 1) { $0.control(.windowReceived, .receiver, 1, 96) }
    try refusedBySender("receipt with another byte count", at: 1) { $0.control(.windowReceived, .receiver, 0, 97) }
    try refusedBySender("the sender's own open value reflected", at: 0) { $0.control(.transferOpen, .sender, 0, 0) }
    try refusedBySender("verdict that is no digest", at: 7) { _ in Array(repeating: 0, count: 64) }
    try refusedBySender("another phase where a window receipt belongs", at: 1) { $0.control(.stageVerified, .receiver, 0, 96) }
    try refusedBySender("receipt replayed from another membership epoch", at: 1) {
        $0.control(.windowReceived, .receiver, 0, 96, in: another)
    }
    try refusedBySender("verdict replayed from another membership epoch", at: 7) {
        $0.control(.stageVerified, .receiver, 6, 508, in: another)
    }
    // The sender's message 0 is its open value, 1 opens window 0, 4 opens window 1, 22 closes.
    try refusedByReceiver("open for another window", at: 4) { $0.control(.windowOpen, .sender, 2, 96) }
    try refusedByReceiver("another phase where a window open belongs", at: 4) { $0.control(.senderComplete, .sender, 1, 96) }
    try refusedByReceiver("open with another byte count", at: 4) { $0.control(.windowOpen, .sender, 1, 97) }
    try refusedByReceiver("the receiver's own open value reflected", at: 0) { $0.control(.transferOpen, .receiver, 0, 0) }
    try refusedByReceiver("close that is no digest, after every digest matched", at: 22) { _ in Array(repeating: 7, count: 64) }
    try refusedByReceiver("window open replayed from another membership epoch", at: 1) {
        $0.control(.windowOpen, .sender, 0, 0, in: another)
    }
    try refusedByReceiver("close replayed from another membership epoch", at: 22) {
        $0.control(.senderComplete, .sender, 6, 508, in: another)
    }

    let split = try TransferScenario(artifact)
    split.receiverSession = another
    let outcome = split.run()
    try checks.refuses("ranks in different membership epochs: the sender", because: wrongFromReceiver) {
        if let error = outcome.sender { throw error }
    }
    try checks.refuses("ranks in different membership epochs: the receiver", because: wrongFromSender) {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("ranks that disagree at the open exchange move no tensor byte",
        split.link.pieceBytesFromSender == 0 && !split.isVerified
        && split.link.fromSender.count == 1 && split.link.fromReceiver.count == 1)
}

private func checkAborts(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    // Pieces 0...2 are sent; the read of piece 3 fails in the middle of window 1.
    let failing = try TransferScenario(artifact)
    failing.source.failingPiece = 3; failing.intake.deferred = true
    var outcome = failing.run()
    try checks.refuses("the sender's read fails: the sender", because: "injected read failure") {
        if let error = outcome.sender { throw error }
    }
    try checks.refuses("the sender's read fails: the receiver", because: "sending rank aborted") {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a failed sender completes its window with placeholders and aborts at the next boundary",
        !failing.isVerified && failing.sender?.servedBytes == 128 && failing.link.pieceBytesFromSender == 176
        && failing.source.log.read == [0, 1, 2, 3] && failing.source.log.placeholders == [3, 4]
        && failing.link.fromSender.last == .control(failing.control(.senderAbort, .sender, 2, 176))
        && failing.link.fromReceiver.last == .control(failing.control(.windowReceived, .receiver, 1, 176)))

    let noticed = try TransferScenario(artifact)
    noticed.source.failingPiece = 3
    outcome = noticed.run()
    try checks.require("a receiver that sees the placeholder first aborts, and each rank reports its own failure",
        !noticed.isVerified && outcome.senderText.contains("injected read failure")
        && outcome.receiverText.contains(contentDiffers)
        && noticed.link.fromReceiver.last == .control(noticed.control(.receiverAbort, .receiver, 1, 176)))

    // Piece 13 is in the last window: the abort takes the place of the close.
    let last = try TransferScenario(artifact)
    last.source.failingPiece = 13; last.intake.deferred = true
    outcome = last.run()
    try checks.require("a sender that fails in the last window aborts where it would have closed",
        !last.isVerified && outcome.senderText.contains("injected read failure")
        && outcome.receiverText.contains(contentDiffers)
        && last.link.fromReceiver.last == .control(last.control(.stageRefused, .receiver, 6, 508))
        && last.link.fromSender.last == .control(last.control(.senderAbort, .sender, 6, 508)))

    // The intake fails on piece 2, the first of window 1.
    let dropping = try TransferScenario(artifact)
    dropping.intake.failingPiece = 2
    outcome = dropping.run()
    try checks.refuses("the receiver's intake fails: the receiver", because: "injected intake failure") {
        if let error = outcome.receiver { throw error }
    }
    try checks.refuses("the receiver's intake fails: the sender", because: "receiving rank aborted") {
        if let error = outcome.sender { throw error }
    }
    try checks.require("a failed receiver takes the rest of its window and aborts at the boundary",
        !dropping.isVerified && dropping.receiver?.receivedBytes == 176 && dropping.link.pieceBytesFromSender == 176
        && dropping.intake.log.accepted == [0, 1, 2] && dropping.intake.log.digestCollections == 1
        && dropping.link.fromReceiver.last == .control(dropping.control(.receiverAbort, .receiver, 1, 176))
        && dropping.sender?.isFinished == false)
}

private func checkDeadlines(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    let second: UInt64 = 1_000_000_000
    // Budget 5 s + 508 ns, progress limit 60 s, margin 2 s: 67 s and 508 ns after its start.
    let late = try TransferScenario(artifact)
    late.senderWatch = late.senderClock.watch(lifetime: late.senderClock.now + 67 * second)
    var outcome = late.run()
    try checks.refuses("a sender too close to its lifetime deadline refuses to begin", because: "cannot finish before") {
        if let error = outcome.sender { throw error }
    }
    try checks.require("a sender that refuses to begin sends no tensor byte",
        late.link.pieceBytesFromSender == 0 && outcome.receiverText.contains("sending rank aborted")
        && late.link.fromSender.last == .control(late.control(.senderAbort, .sender, 0, 0)) && !late.isVerified)

    let starting = try TransferScenario(artifact)
    starting.receiverWatch = starting.receiverClock.watch(startup: starting.receiverClock.now + 67 * second)
    outcome = starting.run()
    try checks.refuses("a receiver too close to its startup deadline refuses", because: "cannot finish before") {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a receiver that refuses aborts at the first boundary",
        starting.link.pieceBytesFromSender == 96 && outcome.senderText.contains("receiving rank aborted")
        && starting.link.fromReceiver.last == .control(starting.control(.receiverAbort, .receiver, 0, 96))
        && !starting.isVerified)

    let fits = try TransferScenario(artifact)
    fits.senderWatch = fits.senderClock.watch(lifetime: fits.senderClock.now + 68 * second,
                                              startup: fits.senderClock.now + 68 * second)
    fits.receiverWatch = fits.receiverClock.watch(lifetime: fits.receiverClock.now + 68 * second)
    outcome = fits.run()
    try checks.require("a transfer that clears both deadlines on both clocks runs",
        outcome.sender == nil && outcome.receiver == nil && fits.isVerified)

    // The sender's clock passes its budget after it has sent piece 2 (its message 5).
    let slow = try TransferScenario(artifact)
    slow.intake.deferred = true
    slow.link.beforeStep = { fromSender, _ in
        if fromSender == 6 { slow.senderClock.now = second + slow.session.plan.budgetNanoseconds }
    }
    outcome = slow.run()
    try checks.refuses("the sender's budget runs out mid-window", because: "exceeded its agreed duration") {
        if let error = outcome.sender { throw error }
    }
    // A second cause after the first does not replace it.
    let twice = try TransferScenario(artifact)
    twice.source.failingPiece = 3; twice.intake.deferred = true
    twice.link.beforeStep = { fromSender, _ in
        if fromSender == 7 { twice.senderClock.now = second + twice.session.plan.budgetNanoseconds }
    }
    let both = twice.run()
    try checks.require("a rank reports its first failure, not a later budget overrun",
        both.senderText.contains("injected read failure") && both.receiverText.contains("sending rank aborted"))
    try checks.require("a sender past its budget finishes the window and aborts at the next boundary",
        outcome.receiverText.contains("sending rank aborted") && slow.sender?.servedBytes == 128
        && slow.link.fromSender.last == .control(slow.control(.senderAbort, .sender, 2, 176)) && !slow.isVerified)

    let waiting = try TransferScenario(artifact)
    waiting.link.beforeStep = { fromSender, _ in
        if fromSender == 6 { waiting.receiverClock.now = 9_000 * second + waiting.session.plan.budgetNanoseconds }
    }
    outcome = waiting.run()
    try checks.refuses("the receiver's budget runs out mid-window", because: "exceeded its agreed duration") {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a receiver past its budget aborts at the boundary",
        outcome.senderText.contains("receiving rank aborted") && !waiting.isVerified
        && waiting.link.fromReceiver.last == .control(waiting.control(.receiverAbort, .receiver, 1, 176)))

    // One nanosecond before the budget ends is still inside it, on a clock hours from the sender's.
    let edge = try TransferScenario(artifact)
    edge.link.beforeStep = { fromSender, _ in
        if fromSender == 6 { edge.receiverClock.now = 9_000 * second + edge.session.plan.budgetNanoseconds - 1 }
    }
    outcome = edge.run()
    try checks.require("the budget is a duration from each rank's own start",
        outcome.sender == nil && outcome.receiver == nil && edge.isVerified)

    // The receiver's verdict is its message 7; its budget ends before the sender's close arrives.
    let closing = try TransferScenario(artifact)
    closing.link.beforeStep = { _, fromReceiver in
        if fromReceiver == 8 { closing.receiverClock.now = 9_000 * second + closing.session.plan.budgetNanoseconds }
    }
    outcome = closing.run()
    try checks.refuses("the receiver's budget runs out before the sender's close", because: "exceeded its agreed duration") {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a receiver past its budget is not verified even after a verified verdict", !closing.isVerified)

    // Cancellation and the lifetime deadline stop a rank at once: nothing more is sent.
    let cancelled = try TransferScenario(artifact)
    cancelled.link.beforeStep = { fromSender, _ in if fromSender == 6 { cancelled.senderClock.cancelled = true } }
    outcome = cancelled.run()
    try checks.refuses("a cancelled sender stops at once", because: "cancelled or past its absolute local deadline") {
        if let error = outcome.sender { throw error }
    }
    try checks.require("a cancelled sender sends no abort; its peer waits out the progress limit",
        cancelled.link.fromSender.last == .piece(2) && outcome.receiverText.contains("no progress") && !cancelled.isVerified)
    let expired = try TransferScenario(artifact)
    expired.link.beforeStep = { fromSender, _ in if fromSender == 6 { expired.receiverClock.now = 9_300 * second } }
    outcome = expired.run()
    try checks.refuses("a receiver past its lifetime stops at once", because: "cancelled or past its absolute local deadline") {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a receiver past its lifetime sends no abort",
        expired.link.fromReceiver.count == 2 && outcome.senderText.contains("no progress") && !expired.isVerified)
}

private func checkIntakeAndMisuse(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    let silent = try TransferScenario(artifact)
    silent.intake.withheldTensor = 5
    var outcome = silent.run()
    try checks.refuses("a tensor that never gets a digest", because: "without a matching digest for every tensor") {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("a missing digest refuses the stage",
        !silent.isVerified && silent.link.fromReceiver.last == .control(silent.control(.stageRefused, .receiver, 6, 508)))

    let unknown = try TransferScenario(artifact)
    unknown.intake.reportsUnknownTensor = true
    outcome = unknown.run()
    try checks.refuses("a digest for a tensor outside the plan", because: contentDiffers) {
        if let error = outcome.receiver { throw error }
    }
    try checks.require("an unplanned digest verifies nothing", !unknown.isVerified)

    let scenario = try TransferScenario(artifact)
    let sender = QwenStageTransferSender(session: scenario.session, source: scenario.source, watch: scenario.senderWatch)
    try checks.refuses("a control value the sender had not asked for", because: "had not asked for") {
        try sender.received(control: scenario.control(.transferOpen, .receiver, 0, 0))
    }
    try checks.refuses("a sender that failed makes no further call", because: "already failed") { _ = try sender.next() }
    let receiver = QwenStageTransferReceiver(session: scenario.session, intake: scenario.intake, watch: scenario.receiverWatch)
    try checks.refuses("a piece the receiver had not asked for", because: "had not asked for") {
        try receiver.received(Data(count: 48), for: scenario.session.plan.pieces[0])
    }
    let ahead = QwenStageTransferReceiver(session: scenario.session, intake: scenario.intake, watch: scenario.receiverWatch)
    _ = try ahead.next()
    try ahead.received(control: scenario.control(.transferOpen, .sender, 0, 0))
    _ = try ahead.next()
    try checks.refuses("a control value the receiver had not asked for", because: "had not asked for") {
        try ahead.received(control: scenario.control(.windowOpen, .sender, 0, 0))
    }
    // Up to the first piece of window 0, then the second piece is offered in its place.
    let disordered = QwenStageTransferReceiver(session: scenario.session, intake: scenario.intake, watch: scenario.receiverWatch)
    _ = try disordered.next()
    try disordered.received(control: scenario.control(.transferOpen, .sender, 0, 0))
    _ = try disordered.next()
    _ = try disordered.next()
    try disordered.received(control: scenario.control(.windowOpen, .sender, 0, 0))
    try checks.refuses("a piece other than the one the receiver asked for", because: "had not asked for") {
        guard case .receivePiece(let piece) = try disordered.next(), piece.index == 0 else {
            throw ProbeError("receiver did not ask for piece 0")
        }
        try disordered.received(Data(count: 48), for: scenario.session.plan.pieces[1])
    }
}
