import Foundation

func checkTransferControl(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    try checkControlValues(artifact, checks)
    try checkSessionBinding(artifact, checks)
    try checkDeadlineRule(checks)
}

private func checkControlValues(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    let session = try artifact.session()
    func values(_ session: QwenStageTransferSession, _ phase: QwenStageTransferControl.Phase = .windowOpen,
                _ role: QwenStageTransferRole = .sender, window: Int = 3, bytes: Int = 272) -> [Int32] {
        QwenStageTransferControl.values(session, phase, from: role, window: window, cumulativeBytes: bytes)
    }
    let value = values(session)
    let preimage = "qwen-stage-transfer-control-v1|" + session.fingerprint + "|windowOpen|sender|3|272"
    try checks.require("a control value is a digest's 64 characters as Int32, like a generation acknowledgement",
        value.count == QwenStageTransferControl.valueCount && value.count == 64
        && value == sha256(Data(preimage.utf8)).utf8.map(Int32.init)
        && value.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    let phases: [QwenStageTransferControl.Phase] = [.transferOpen, .windowOpen, .senderAbort, .windowReceived,
        .receiverAbort, .stageVerified, .stageRefused, .senderComplete]
    try checks.require("every phase, rank, window index and cumulative byte count gives its own value",
        Set(phases.map { values(session, $0) }).count == phases.count
        && values(session, .transferOpen, .receiver) != values(session, .transferOpen, .sender)
        && values(session, window: 4) != value && values(session, bytes: 273) != value)
    let fingerprint = sha256(Data(["qwen-stage-transfer-session-v1", String(repeating: "e", count: 64),
        session.plan.fingerprint, artifact.inventory.encodedSHA256].joined(separator: "|").utf8))
    try checks.require("the session binds the load agreement, the plan and the pinned inventory",
        session.fingerprint == fingerprint
        && (try artifact.session(epoch: "f")).fingerprint != fingerprint
        && (try artifact.session(stages: [1])).fingerprint != fingerprint
        && values(try artifact.session(epoch: "f")) != value)
    // The same tensors with one content digest changed: another pinned inventory.
    var records = artifact.inventory.records
    records[0] = try .init(source: records[0].source, contentSHA256: String(repeating: "0", count: 64))
    let repinned = try QwenStageTransferSession(loadAgreementFingerprint: String(repeating: "e", count: 64),
        plan: session.plan, inventory: .init(records: records))
    try checks.require("ranks with different pinned inventories compute different control values",
        repinned.fingerprint != session.fingerprint && values(repinned) != value)
    try checks.require("each planned tensor is joined to its pinned record, in plan order",
        session.records.map { $0.source.layout.canonicalName } == session.plan.tensors.map(\.sourceName)
        && session.records.allSatisfy { record in
            artifact.inventory.records.contains(record) && sha256(artifact.content[record.source.layout.canonicalName]!) == record.contentSHA256
        })
}

private func checkSessionBinding(_ artifact: TinyStageArtifact, _ checks: StageTransferChecks) throws {
    let plan = try artifact.session().plan
    func session(agreement: String = String(repeating: "e", count: 64),
                 inventory: LayerStageTensorContentInventory) throws {
        _ = try QwenStageTransferSession(loadAgreementFingerprint: agreement, plan: plan, inventory: inventory)
    }
    try checks.refuses("load agreement that is not a SHA-256", because: "load agreement's SHA-256") {
        try session(agreement: "epoch-7", inventory: artifact.inventory)
    }
    let pinned = "differs from the pinned content inventory"
    try checks.refuses("planned tensor the pinned inventory does not hold", because: pinned) {
        try session(inventory: .init(records: Array(artifact.inventory.records.dropLast())))
    }
    func replaced(_ index: Int, shape: [Int], dtype: String) throws -> LayerStageTensorContentInventory {
        var records = artifact.inventory.records
        let source = records[index].source
        records[index] = try .init(source: .init(layout: .init(canonicalName: source.layout.canonicalName,
            shape: shape, sourceDType: dtype, byteCount: source.layout.byteCount),
            sourceFile: source.sourceFile, sourceOffset: source.sourceOffset), contentSHA256: records[index].contentSHA256)
        return try .init(records: records)
    }
    // Record 0 is a U32 [4, 4]: the same 64 bytes under another shape, then under another dtype.
    try checks.refuses("pinned shape differs from the planned tensor", because: pinned) {
        try session(inventory: replaced(0, shape: [2, 8], dtype: "U32"))
    }
    try checks.refuses("pinned dtype differs from the planned tensor", because: pinned) {
        try session(inventory: replaced(0, shape: [4, 4], dtype: "F32"))
    }
}

private func checkDeadlineRule(_ checks: StageTransferChecks) throws {
    let second: UInt64 = 1_000_000_000
    // Start at 100 s with a 9 s budget and a 60 s progress limit: the rank must
    // be able to fail by itself by 100 + 9 + 60 + 2 = 171 s.
    func deadline(lifetime: UInt64, startup: UInt64? = nil, start: UInt64 = 100 * second,
                  budget: UInt64 = 9 * second) throws -> UInt64 {
        try QwenStageTransferDeadlines(lifetimeUptimeNanoseconds: lifetime, startupUptimeNanoseconds: startup,
            progressTimeoutNanoseconds: 60 * second).transferDeadline(start: start, budgetNanoseconds: budget)
    }
    try checks.require("a transfer that fits is given start plus budget as its own deadline",
        try deadline(lifetime: 300 * second) == 109 * second
        && deadline(lifetime: 300 * second, startup: 200 * second) == 109 * second
        && deadline(lifetime: 171 * second + 1) == 109 * second
        && deadline(lifetime: 300 * second, startup: 171 * second + 1) == 109 * second)
    try checks.require("the margin is two seconds and the budget is five seconds plus a nanosecond per byte",
        QwenStageTransferDeadlines.marginNanoseconds == 2 * second
        && QwenStageTransferPlan.budgetBaseNanoseconds == 5 * second)
    let rule = "cannot finish before this rank's startup and lifetime deadlines"
    try checks.refuses("transfer that would end at the lifetime deadline", because: rule) {
        _ = try deadline(lifetime: 171 * second)
    }
    try checks.refuses("transfer that fits the lifetime but not the startup deadline", because: rule) {
        _ = try deadline(lifetime: 300 * second, startup: 171 * second)
    }
    try checks.refuses("budget alone fits but the progress limit does not", because: rule) {
        _ = try deadline(lifetime: 120 * second)
    }
    try checks.refuses("budget that runs off the end of the clock", because: rule) {
        _ = try deadline(lifetime: .max, budget: .max - 50 * second)
    }
}
