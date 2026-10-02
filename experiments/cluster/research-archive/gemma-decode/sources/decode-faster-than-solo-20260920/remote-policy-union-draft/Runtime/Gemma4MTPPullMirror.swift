import Foundation

/// Assistant's scalar mirror. Target messages carry target decisions, never
/// locally fabricated target completion. Only the target may publish output.
final class Gemma4MTPPullMirror {
    typealias Record = Gemma4MTPPullRecord
    enum Action {
        case install(AsyncMTPProposalLedger.BranchID)
        case generate(AsyncMTPProposalLedger.Grant)
        case deliver([Int])
        case resolved
        case retire
        case finish
        case cancel
    }
    private(set) var ledger: AsyncMTPProposalLedger
    private(set) var branch: AsyncMTPProposalLedger.BranchID?
    private(set) var pendingGrant: AsyncMTPProposalLedger.Grant?
    private var completedTokens: [Int]?
    private var command: Record?
    private var nextSequence: UInt64 = 0
    private var failed = false
    let scopeSHA256: String

    init(scope: AsyncMTPProposalLedger.Scope, requestSHA256: String, inputFrontier: Int, seed: Int,
         maximumInputFrontier: Int, bonusContinuationPolicy: AsyncMTPBonusContinuationPolicy = .strict,
         maximumProducerGrantTokens: Int = 2) throws {
        guard (1...8319).contains(maximumInputFrontier), requestSHA256.utf8.count == 64,
              requestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Record.Failure(reason:"Pull request fingerprint/context differs from the admitted auxiliary scope")
        }
        ledger = try .init(scope: scope, inputFrontier: inputFrontier, seedToken: seed,
            maximumDraftTokens: 2, maximumInputFrontier: maximumInputFrontier, vocabularySize: 262_144,
            bonusContinuationPolicy: bonusContinuationPolicy, maximumProducerGrantTokens:maximumProducerGrantTokens)
        scopeSHA256 = Record.scopeFingerprint(scope, requestSHA256:requestSHA256,
            initialFrontier:inputFrontier, maximumInputFrontier:maximumInputFrontier)
    }

    func accept(_ value: Record) throws -> Action {
        do {
            guard !failed, command == nil, value.sequence == nextSequence,
                  nextSequence < UInt64.max, value.scopeSHA256 == scopeSHA256 else { throw failure("Scope, sequence or request lifecycle differs") }
            command = value
            if value.kind == .seed {
                guard pendingGrant == nil, branch == nil, (1...3).contains(value.hiddenDType),
                      value.snapshotSHA256 == Record.captureFingerprint(scope: scopeSHA256,
                        ordinal: value.branchOrdinal, frontier: ledger.inputFrontier,
                        seed: ledger.seedToken, hiddenDType: value.hiddenDType) else { throw failure("Seed lacks a fresh exact capture identity") }
                let id = try ledger.startBranch(snapshotFrontier: value.snapshotFrontier, snapshotSHA256: value.snapshotSHA256)
                var expected = record(.seed, branch: id)
                expected.frontier = ledger.inputFrontier; expected.seed = ledger.seedToken; expected.hiddenDType = value.hiddenDType
                try equal(value, expected); branch = id
                return .install(id)
            }
            guard let branch else { throw failure("Command has no installed branch") }
            switch value.kind {
            case .credit:
                guard pendingGrant == nil else { throw failure("A native credit is already outstanding") }
                let grant = try ledger.grant(value.count)
                var expected = record(.credit, branch: branch)
                expected.frontier = ledger.inputFrontier; expected.seed = ledger.seedToken
                expected.firstPosition = grant.firstPosition; expected.count = grant.count
                try equal(value, expected); pendingGrant = grant
                return .generate(grant)
            case .pull:
                guard let grant = pendingGrant, let tokens = completedTokens else { throw failure("Pull precedes completed credited work") }
                var expected = record(.pull, branch: branch)
                expected.firstPosition = grant.firstPosition; expected.count = grant.count
                try equal(value, expected)
                try ledger.receive(grant, tokens: tokens)
                return .deliver(tokens)
            case .resolve:
                guard pendingGrant == nil, (1...2).contains(value.count), value.tokens.count == value.count + 1 else {
                    throw failure("Resolution must follow completed pull and contain every target column")
                }
                let window = try ledger.beginVerification(draftCount: value.count)
                let result = try ledger.resolve(window, targetTokens: value.tokens)
                var expected = record(.resolve, branch: branch)
                expected.count = window.draftTokens.count; expected.windowOrdinal = window.ordinal
                expected.frontier = result.nextInputFrontier; expected.seed = result.nextSeedToken
                expected.accepted = result.acceptedDraftTokens; expected.tokens = value.tokens
                try equal(value, expected)
                // This mirror consumes the authenticated peer's decision. It
                // establishes no target-native fact and publishes no tokens.
                try ledger.commit(result, actualCommittedInputFrontier: value.frontier,
                    targetEvaluationCompleted: true, rejectedSuffixReconciled: true)
                return .resolved
            case .retire:
                try equal(value, record(.retire, branch: branch))
                guard ledger.requiresBranchRetirement else { throw failure("Retire cannot replace a live usable branch") }
                return .retire
            case .finish:
                try equal(value, record(.finish, branch: branch)); try ledger.finishRequest(); return .finish
            case .cancel:
                try equal(value, record(.cancel, branch: branch)); ledger.cancelRequest(); return .cancel
            default: throw failure("A response cannot be used as a command")
            }
        } catch { failed = true; throw error }
    }

    func generationCompleted(_ grant: AsyncMTPProposalLedger.Grant, tokens: [Int]) throws {
        guard !failed, pendingGrant == grant, completedTokens == nil, command == nil,
              tokens.count == grant.count, tokens.allSatisfy({ (0..<262_144).contains($0) }) else { throw failure("Native result differs from exact outstanding credit") }
        completedTokens = tokens
    }

    /// Runtime calls this only after the action's actual work. For retirement,
    /// that includes native fences AND dropping branch/capture/batch roots.
    func response(_ kind: Record.Kind) throws -> Record {
        guard !failed, let command else { throw failure("Response has no command") }
        let allowed: [Record.Kind:Record.Kind] = [.seed:.seeded, .credit:.queued, .pull:.proposals,
            .resolve:.resolved, .retire:.retired, .finish:.finished, .cancel:.cancelled]
        guard allowed[command.kind] == kind else { throw failure("Response opcode differs") }
        var result = command.changingKind(kind)
        if kind == .proposals {
            guard let completedTokens else { throw failure("Proposal result is not completed") }
            result.tokens = completedTokens
        }
        if [.retired, .finished, .cancelled].contains(kind) {
            guard let branch else { throw failure("Retirement has no branch") }
            try ledger.branchRetired(branch, nativeWorkCompleted: true, payloadLeasesReleased: true)
            self.branch = nil; pendingGrant = nil; completedTokens = nil
        }
        return result
    }

    func responseSent() throws {
        guard !failed, let command, nextSequence < UInt64.max else { throw failure("Response completion is replayed") }
        if command.kind == .pull { pendingGrant = nil; completedTokens = nil }
        self.command = nil; nextSequence += 1
    }
    func poison() { failed = true }
    private func record(_ kind: Record.Kind, branch: AsyncMTPProposalLedger.BranchID) -> Record {
        .init(kind: kind, sequence: nextSequence, scopeSHA256: scopeSHA256, branch: branch)
    }
    private func equal(_ actual: Record, _ expected: Record) throws {
        guard actual == expected else { throw failure("Command fields are noncanonical, stale or substituted") }
    }
    private func failure(_ reason: String) -> Record.Failure { .init(reason: reason) }
}
