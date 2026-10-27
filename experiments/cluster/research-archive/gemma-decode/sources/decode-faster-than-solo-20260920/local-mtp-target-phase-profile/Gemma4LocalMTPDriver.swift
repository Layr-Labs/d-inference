import Foundation
import MLX
import MLXLMCommon
@_spi(DarkbloomCluster) import MLXLLM

struct Gemma4LocalMTPWindowTiming: Encodable {
    let width: Int, accepted: Int
    let proposalNanoseconds: UInt64, targetNanoseconds: UInt64, selectionNanoseconds: UInt64
    let reconcileNanoseconds: UInt64, conditioningNanoseconds: UInt64
    let targetPrepareNanoseconds: UInt64, targetAdmissionNanoseconds: UInt64, targetExecutionNanoseconds: UInt64
}

struct Gemma4LocalMTPSample: Encodable {
    let ordinal: Int, warmup: Bool
    let requestSHA256: String, selectedTokenIDs: [Int]
    let committedTokens: Int
    let prefillNanoseconds: UInt64, decodeNanoseconds: UInt64
    let prefillTPS: Double, decodeTPS: Double
    let proposalTokens: Int, acceptedProposalTokens: Int, verifiedWindows: Int, seedSteps: Int
    let verificationWidths: [Int], acceptedPrefixes: [Int]
    let windowTimings: [Gemma4LocalMTPWindowTiming]
    let mtpEnabled = true, remoteAssistant = false
    let timingsAreSameProcess = true, rejectedWorkIncluded = true
    let targetBatchNumericsQualified = false
}

/// Local, freshly conditioned assistant baseline for the distributed candidate.
/// All target state remains in the same registered/window-aware request owner.
/// Loading and auxiliary reservation are supplied by the cohort's outer owner.
enum Gemma4LocalMTPDriver {
    static func execute(input: Gemma4BenchmarkRequestInput, session: Gemma4OwnedForwardSession,
        assistant: Gemma4AssistantDraftModel, maximumDraftTokens: Int,
        admitVerification: (CBv2AttentionVerificationPlan) throws -> Void,
        requireGrant: (_ count: Int, _ capture: Gemma4OwnedMTPConditioning) throws -> Void,
        observeVerifiedWindow: (Gemma4OwnedMTPWindow, Int) throws -> Void = { _, _ in },
        beforeFinish: (Gemma4OwnedForwardSession, [Int]) throws -> Void = { _, _ in },
        check: () throws -> Void
    ) throws -> Gemma4LocalMTPSample {
        guard input.job.rank == nil, !input.job.captureEvidence, [1,2].contains(maximumDraftTokens), input.request.outputCount >= 2,
              case .full(let full) = session.loaded.model else {
            throw ProbeError("Local MTP requires an admitted full target and bounded verification depth")
        }
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            func greedy(_ logits: MLXArray, width: Int) throws -> [Int] {
                guard logits.shape == [1, width, input.request.profile.vocabularySize] else {
                    throw ProbeError("Local MTP target logits shape differs")
                }
                let tokens = argMax(logits, axis: -1), finite = all(isFinite(logits))
                eval(tokens, finite); try checked()
                guard finite.item(Bool.self), tokens.dtype == .uint32 else {
                    throw ProbeError("Local MTP target returned nonfinite logits or invalid argmax")
                }
                let result = tokens.asArray(UInt32.self).map(Int.init)
                guard result.count == width else { throw ProbeError("Local MTP target column count differs") }
                return result
            }
            do {
                try checked()
                let conditioning = Gemma4MTPConditioning(targetConfiguration: full.textModel.configuration,
                    scaledEmbedding: { full.textModel.embedTokensForDrafter($0) })
                try assistant.bind(conditioning: conditioning)
                defer { assistant.unbind() }
                var selected: [Int] = []
                var proposalCount = 0, acceptedCount = 0, seedSteps = 0
                var widths: [Int] = [], accepts: [Int] = []
                var timings: [Gemma4LocalMTPWindowTiming] = []
                var capture: Gemma4OwnedMTPConditioning?
                let start = DispatchTime.now().uptimeNanoseconds
                let promptFrames = (input.request.promptCount + input.request.chunkSize - 1) / input.request.chunkSize
                for sequence in 0..<promptFrames {
                    try autoreleasepool {
                        try checked()
                        let frame = try Gemma4BenchmarkFrames.frame(sequence, request: input.request)
                        let tokens = Array(input.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                        let output = try session.prefillChunk(tokens, offset: frame.tokenOffset,
                            final: frame.finalPromptChunk, check: checked)
                        switch output {
                        case .evaluationHandle:
                            guard !frame.finalPromptChunk else { throw ProbeError("Local MTP lost final prompt logits") }
                        case .logits(let logits):
                            guard frame.finalPromptChunk else { throw ProbeError("Local MTP prompt projected early") }
                            selected = try greedy(logits.reshaped([1,1,input.request.profile.vocabularySize]), width: 1)
                        case .residual: throw ProbeError("Local MTP full target returned a residual")
                        }
                    }
                }
                guard selected.count == 1 else { throw ProbeError("Local MTP prompt did not select one token") }
                let first = DispatchTime.now().uptimeNanoseconds
                while selected.count < input.request.outputCount {
                    try autoreleasepool {
                        try checked()
                        guard let seed = selected.last else { throw ProbeError("Local MTP has no confirmed seed") }
                        let remaining = input.request.outputCount - selected.count
                        let k = capture == nil ? 0 : min(maximumDraftTokens, remaining - 1)
                        var proposals: [Int] = []
                        let proposalStart = DispatchTime.now().uptimeNanoseconds
                        if k > 0 {
                            guard let capture else { throw ProbeError("Local MTP has no frozen capture") }
                            try requireGrant(k, capture)
                            try checked()
                            let row = CBv2MTPRowCapture(fullKeys: capture.fullKeys, fullValues: capture.fullValues,
                                slidingKeys: capture.slidingKeys, slidingValues: capture.slidingValues,
                                slidingStart: capture.frontier - capture.slidingKeys.dim(2), anchor: capture.frontier)
                            let branch = try Gemma4MTPFrozenProposalBranch(drafter: assistant,
                                conditioning: conditioning, row: row, seedToken: seed,
                                hidden: capture.hidden, maximumProposals: k)
                            let batch = try branch.build(grantedCount: k)
                            eval(batch.tokens, batch.lastHidden); try checked()
                            guard batch.tokens.dtype == .int32, batch.tokens.shape == [1,k] else {
                                throw ProbeError("Local MTP proposal geometry differs")
                            }
                            proposals = batch.tokens.asArray(Int32.self).map(Int.init)
                            proposalCount += proposals.count
                        } else { seedSteps += 1 }
                        let targetStart = DispatchTime.now().uptimeNanoseconds
                        let window = try session.evaluateMTPInputs([seed] + proposals,
                            offset: session.committedTokens, admit: admitVerification, check: checked)
                        let selectionStart = DispatchTime.now().uptimeNanoseconds
                        let target = try greedy(window.logits, width: 1 + k)
                        var accepted = 0
                        while accepted < k && proposals[accepted] == target[accepted] { accepted += 1 }
                        let keep = accepted + 1
                        let reconcileStart = DispatchTime.now().uptimeNanoseconds
                        _ = try session.reconcileMTP(window, keeping: keep, check: checked)
                        let reconcileEnd = DispatchTime.now().uptimeNanoseconds
                        try observeVerifiedWindow(window, keep)
                        try checked()
                        selected.append(contentsOf: target.prefix(keep))
                        widths.append(1 + k); accepts.append(accepted); acceptedCount += accepted
                        let conditioningStart = DispatchTime.now().uptimeNanoseconds
                        if selected.count < input.request.outputCount {
                            capture = try session.mtpConditioning(after: window, check: checked)
                        } else { capture = nil }
                        let conditioningEnd = DispatchTime.now().uptimeNanoseconds
                        timings.append(.init(width:1+k,accepted:accepted,
                            proposalNanoseconds:targetStart-proposalStart,targetNanoseconds:selectionStart-targetStart,
                            selectionNanoseconds:reconcileStart-selectionStart,reconcileNanoseconds:reconcileEnd-reconcileStart,
                            conditioningNanoseconds:conditioningEnd-conditioningStart,
                            targetPrepareNanoseconds:window.prepareNanoseconds,
                            targetAdmissionNanoseconds:window.admissionNanoseconds,
                            targetExecutionNanoseconds:window.executionNanoseconds))
                        try checked()
                    }
                }
                let last = DispatchTime.now().uptimeNanoseconds
                guard selected.count == input.request.outputCount,
                      session.committedTokens == input.request.finalCommittedTokens,
                      first > start, last > first else {
                    throw ProbeError("Local MTP completed output or input frontier differs")
                }
                let frontier = session.committedTokens
                capture = nil
                try beforeFinish(session, selected)
                try checked()
                try session.finish(.length, selectedTokenCount: selected.count, lastTokenID: selected.last!)
                try checked()
                return .init(ordinal: input.ordinal, warmup: input.ordinal == 0,
                    requestSHA256: input.request.fingerprint, selectedTokenIDs: selected,
                    committedTokens: frontier, prefillNanoseconds: first-start, decodeNanoseconds: last-first,
                    prefillTPS: Double(input.request.promptCount)*1e9/Double(first-start),
                    decodeTPS: Double(selected.count-1)*1e9/Double(last-first), proposalTokens: proposalCount,
                    acceptedProposalTokens: acceptedCount, verifiedWindows: widths.count,
                    seedSteps: seedSteps, verificationWidths: widths, acceptedPrefixes: accepts, windowTimings: timings)
            } catch { try native.check(); throw error }
        }
    }
}
