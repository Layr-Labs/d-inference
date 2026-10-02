import MLX
@_spi(DarkbloomCluster) import MLXLLM

/// Retain this service in the original native owner through terminal cleanup,
/// including failures. A failed GPU fence deliberately leaves its roots owned.
final class Gemma4MTPPullAssistant {
    enum Completion { case finished, cancelled }
    private let channel: Gemma4MTPPullChannel
    private var mirror: Gemma4MTPPullMirror?
    private let scope: AsyncMTPProposalLedger.Scope
    private let initialFrontier: Int
    private let bonusContinuationPolicy: AsyncMTPBonusContinuationPolicy
    private let worker: Gemma4MTPPullBatchOwner
    private let auxiliary: Gemma4MTPAuxiliaryOwner
    private let receiveStaging = Gemma4MTPPullReceiveStaging()
    private var started = false

    init(channel: Gemma4MTPPullChannel, scope: AsyncMTPProposalLedger.Scope,
         initialFrontier: Int, assistant: Gemma4AssistantDraftModel,
         conditioning: Gemma4MTPConditioning, auxiliary: Gemma4MTPAuxiliaryOwner,
         bonusContinuationPolicy: AsyncMTPBonusContinuationPolicy = .strict) throws {
        let fingerprint = Gemma4MTPPullRecord.scopeFingerprint(scope,requestSHA256:auxiliary.budget.requestSHA256,
            initialFrontier:initialFrontier,maximumInputFrontier:auxiliary.budget.maximumFrontier)
        guard channel.role == .assistant, channel.scopeSHA256 == fingerprint,
              (1..<auxiliary.budget.maximumFrontier).contains(initialFrontier) else {
            throw ProbeError("Remote MTP service differs from its original request scope")
        }
        self.channel = channel; self.scope = scope; self.initialFrontier = initialFrontier; self.auxiliary = auxiliary
        self.bonusContinuationPolicy = bonusContinuationPolicy
        worker = try .init(assistant:assistant,conditioning:conditioning,auxiliary:auxiliary)
    }

    func run(check: (Gemma4BenchmarkGuardObservation?) throws -> Void) throws -> Completion {
        guard !started else { throw ProbeError("Remote MTP service cannot restart") }
        started = true
        do {
            return try MLX.withError { native in
                func checked() throws {
                    // Each wire/model callback owns a fresh, nonescaping scope.
                    // No observation survives the return to that operation.
                    let observation = Gemma4BenchmarkGuardObservation(mode:.entryOwner,deadline:auxiliary.deadline)
                    defer { observation.close() }
                    try native.check(); try check(observation)
                    try auxiliary.checkStandalone(observation:observation); try native.check()
                    try observation.finish(deadline:auxiliary.deadline)
                }
                func reply(_ kind: Gemma4MTPPullRecord.Kind) throws {
                    guard let mirror = self.mirror else { throw ProbeError("Remote MTP mirror has no initial seed") }
                    let value = try mirror.response(kind)
                    try channel.reply(value,check:checked); try mirror.responseSent()
                }
                while true {
                    try checked()
                    let command = try channel.receiveCommand(check:checked)
                    if mirror == nil {
                        guard command.kind == .seed, command.sequence == 0, command.frontier == initialFrontier else {
                            throw ProbeError("Remote MTP first command is not the actual target's initial seed")
                        }
                        // The seed is a target-generated token, not a launch-time
                        // guessed ID. Its exact value is then bound into BranchID.
                        mirror = try .init(scope:scope,requestSHA256:auxiliary.budget.requestSHA256,
                            inputFrontier:initialFrontier,seed:command.seed,maximumInputFrontier:auxiliary.budget.maximumFrontier,
                            bonusContinuationPolicy:bonusContinuationPolicy)
                    }
                    guard let mirror else { throw ProbeError("Remote MTP mirror initialization failed") }
                    switch try mirror.accept(command) {
                    case .install(let id):
                        let plan = try Gemma4MTPPullTransferPlan(frontier:id.snapshotFrontier,hiddenDType:command.hiddenDType)
                        guard plan.frontier <= auxiliary.budget.maximumFrontier else { throw ProbeError("Remote MTP receive exceeds admitted snapshot frontier") }
                        try checked()
                        try Gemma4MTPPullSnapshot.requireReceiverAllowance(plan:plan,budget:auxiliary.budget)
                        try checked()
                        let capture = try Gemma4MTPPullSnapshot.receive(through:channel,plan:plan,staging:receiveStaging,check:checked)
                        try worker.install(capture,id:id,check:checked)
                        // Receive/concat fences passed and the branch now owns
                        // all immutable capture arrays; failure keeps staging.
                        try checked(); receiveStaging.installedAfterFence()
                        try reply(.seeded)
                    case .generate(let grant):
                        try worker.prepare(grant,check:checked)
                        // Queued is ONLY credit acceptance. Completion is a later
                        // pull; never claim GPU/receiver consumption at this ACK.
                        try reply(.queued)
                        let tokens = try worker.execute(check:checked)
                        try mirror.generationCompleted(grant,tokens:tokens)
                    case .deliver:
                        try reply(.proposals); try worker.delivered()
                    case .resolved: try reply(.resolved)
                    case .retire:
                        try worker.retire(check:checked); try reply(.retired)
                    case .finish:
                        try worker.retire(check:checked); try worker.unbindAfterRetirement()
                        try reply(.finished); return .finished
                    case .cancel:
                        try worker.retire(check:checked); try worker.unbindAfterRetirement()
                        try reply(.cancelled); return .cancelled
                    }
                }
            }
        } catch { mirror?.poison(); worker.poison(); throw error }
    }
}
