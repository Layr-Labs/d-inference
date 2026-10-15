import Foundation
import MLX

enum Gemma4RemoteMTPDriver {
    static func execute(input: Gemma4RemoteMTPInput, ordinal: Int, session: Gemma4OwnedForwardSession,
                        group: Collective, resources: Gemma4MTPRemoteTargetResources,
                        lifetime: Gemma4RemoteMTPNativeLifetime, sidecars: Gemma4BenchmarkSidecars,
                        denseProjection: Gemma4MTPDenseProjection? = nil,
                        check: () throws -> Void) throws -> Gemma4RemoteMTPSample {
        let requestInput = try input.local.iteration(ordinal), request = requestInput.request
        guard input.job.rank == 1, group.rank == 1, group.transport == .jaccl,
              case .full = session.loaded.model, lifetime.target == nil else {
            throw ProbeError("Remote MTP driver needs the original full target on rank1")
        }
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            func greedy(_ logits: MLXArray, width: Int) throws -> [Int] {
                guard logits.shape == [1,width,262_144] else { throw ProbeError("Remote MTP target logits shape differs") }
                let tokens = argMax(logits,axis:-1), finite = all(isFinite(logits))
                eval(tokens,finite); try Gemma4MTPPullNativeFence.join(check:checked)
                guard tokens.dtype == .uint32, finite.item(Bool.self) else { throw ProbeError("Remote MTP target sampling is invalid") }
                let result = tokens.asArray(UInt32.self).map(Int.init)
                guard result.count == width else { throw ProbeError("Remote MTP target sampling width differs") }
                return result
            }
            func admit(_ plan: CBv2AttentionVerificationPlan) throws { try resources.admitVerification(plan); try checked() }
            do {
                let binding = try session.shortDiagnosticBinding()
                var selected: [Int] = [], widths: [Int] = [], accepts: [Int] = []
                let start = DispatchTime.now().uptimeNanoseconds
                for sequence in 0..<request.prefillFrameCount {
                    try autoreleasepool {
                        let frame = try Gemma4BenchmarkFrames.frame(sequence,request:request)
                        let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)])
                        let output = try session.prefillChunk(tokens,offset:frame.tokenOffset,final:frame.finalPromptChunk,check:checked)
                        switch output {
                        case .evaluationHandle: guard !frame.finalPromptChunk else { throw ProbeError("Remote MTP lost prompt logits") }
                        case .logits(let logits):
                            guard frame.finalPromptChunk else { throw ProbeError("Remote MTP prompt projected early") }
                            selected = try greedy(logits.reshaped([1,1,262_144]),width:1)
                        case .residual: throw ProbeError("Remote MTP full target returned residual")
                        }
                    }
                }
                guard selected.count == 1 else { throw ProbeError("Remote MTP prompt selected no token") }
                let first = DispatchTime.now().uptimeNanoseconds
                // Actual width-one prime creates target hidden/KV at P+1. Its
                // second output is the first remote seed, never a guessed token.
                var lastWindow: Gemma4OwnedMTPWindow? = try session.evaluateMTPInputs([selected[0]],
                    offset:session.committedTokens,denseProjection:denseProjection,admit:admit,check:checked)
                selected += try greedy(lastWindow!.logits,width:1)
                _ = try session.reconcileMTP(lastWindow!,keeping:1,check:checked)
                widths.append(1); accepts.append(0)
                let channel = try Gemma4MTPPullChannel(collective:group,role:.target,targetRank:1,scopeSHA256:input.wireScope(ordinal))
                let target = try Gemma4MTPPullTarget(channel:channel,scope:input.requestScope(ordinal),
                    requestSHA256:input.resourceRequestSHA256,initialFrontier:session.committedTokens,
                    initialSeed:selected.last!,maximumInputFrontier:request.finalCommittedTokens)
                lifetime.target = target
                func reseed(_ window: Gemma4OwnedMTPWindow) throws {
                    try target.reseed(after:window,session:session,admitSend:{ plan in
                        try resources.admitSend(plan); try checked()
                    },check:checked)
                }
                try reseed(lastWindow!)
                var lastKeep = 1, stopped = false, restarts = 0
                while selected.count < request.outputCount {
                    try autoreleasepool {
                        let remaining = request.outputCount-selected.count
                        if remaining == 1 {
                            try target.finish(check:checked); stopped = true
                            lastWindow = nil
                            let window = try session.evaluateMTPInputs([selected.last!],offset:session.committedTokens,denseProjection:denseProjection,admit:admit,check:checked)
                            let token = try greedy(window.logits,width:1)
                            _ = try session.reconcileMTP(window,keeping:1,check:checked)
                            selected += token; widths.append(1); accepts.append(0); lastWindow = window; lastKeep = 1
                        } else {
                            try target.fill(draftCount:min(2,remaining-1),check:checked)
                            lastWindow = nil
                            let result = try target.verify(draftCount:min(2,remaining-1),session:session,
                                admitVerification:admit,denseProjection:denseProjection,check:checked)
                            selected += result.confirmedTokens
                            widths.append(result.window.inputTokens.count); accepts.append(result.acceptedDraftTokens)
                            lastWindow = result.window; lastKeep = result.confirmedTokens.count
                            if result.requiresReseed && selected.count < request.outputCount-1 {
                                try target.retireRejectedBranch(check:checked); try reseed(result.window); restarts += 1
                            }
                        }
                        try checked()
                    }
                }
                if !stopped { try target.finish(check:checked) }
                let last = DispatchTime.now().uptimeNanoseconds
                guard selected.count == request.outputCount, session.committedTokens == request.finalCommittedTokens,
                      target.ledger.controlStateRetired, let terminal = lastWindow, first > start, last > first else {
                    throw ProbeError("Remote MTP final frontier/output or auxiliary retirement differs")
                }
                let row = terminal.logits[0...,(lastKeep-1)..<lastKeep,0...].reshaped([1,262_144])
                let evidence = try Gemma4RemoteMTPRequestEvidence.capture(row:row,session:session,input:requestInput,
                    selected:selected,enabled:input.local.job.captureEvidence,sidecars:sidecars,check:checked)
                lastWindow = nil
                try session.finish(.length,selectedTokenCount:selected.count,lastTokenID:selected.last!)
                try Gemma4MTPPullNativeFence.join(check:checked)
                guard session.isClosed, !session.isFailed else { throw ProbeError("Remote MTP target request did not retire") }
                let counters = target.ledger.counters
                lifetime.target = nil
                return try .init(ordinal:ordinal,warmup:ordinal==0,requestID:request.requestID.uuidString.lowercased(),
                    requestSHA256:request.fingerprint,scopeSHA256:input.wireScope(ordinal),selectedTokenIDs:selected,
                    selectedTokenIDsSHA256:qwenGenerationTokenHash(selected),committedTokens:session.committedTokens,binding:binding,
                    prefillNanoseconds:first-start,decodeNanoseconds:last-first,
                    prefillTPS:Double(request.promptCount)*1e9/Double(first-start),decodeTPS:Double(selected.count-1)*1e9/Double(last-first),
                    generatedProposals:counters.generated,offeredProposals:counters.offered,acceptedProposals:counters.accepted,
                    branchRestarts:restarts,reusedProposalsOffered:counters.reusedProposalsOffered,
                    verificationWidths:widths,acceptedPrefixes:accepts,evidence:evidence)
            } catch {
                let primary = error
                if let target = lifetime.target { try? target.cancel(session:session,check:checked) }
                else { try? session.cancel() }
                lifetime.retainFailedUntilProcessExit()
                throw primary
            }
        }
    }
}
