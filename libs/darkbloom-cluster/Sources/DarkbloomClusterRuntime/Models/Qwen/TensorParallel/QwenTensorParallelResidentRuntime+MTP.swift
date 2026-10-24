import DarkbloomClusterProtocol
import Foundation
import MLX

extension QwenTensorParallelResidentRuntime {
    static func mtpAllowance(_ quote: QwenTensorParallelMTPBudget) -> QwenResidentRequestAllowance {
        .init(stateBytes: quote.allowance.reservedBytes, fusionBytes: 0,
            reservedBytes: quote.allowance.reservedBytes, contextTokens: quote.allowance.maximumContextTokens)
    }

    /// A single request owns the target pages and assistant backlog. Stops
    /// become bilateral votes only between completed native phases. Accepted
    /// target state is settled on both ranks before any token is published.
    func generateMTP(_ reserved: Reserved, onCommittedToken: (Int, Int, Int) throws -> Bool) throws
        -> QwenResidentGenerationCompletion {
        guard batchLanes == 1, reserved.media == nil, let model, let mtpHead, let mtpHost, let mtpTerms,
              mtpHost.isDrained, failedMTPDecoder == nil, failedMTPTarget == nil,
              codec != nil, group.sealed != nil, group.requiresSealing else {
            throw ProbeError("Qwen TP MTP owner is not ready for an exclusive text request")
        }
        return try MLX.withError { nativeError in
            var request = reserved.request
            let rank = collective.rank
            // Compare the complete digest, including the typed LOAD policy.
            let fingerprint = sha256(try canonicalJSONData([request.fingerprint, loadAgreement]))
            for lower in stride(from: 0, to: fingerprint.count, by: 16) {
                let start = fingerprint.index(fingerprint.startIndex, offsetBy: lower)
                let end = fingerprint.index(start, offsetBy: 16)
                guard let word = UInt64(fingerprint[start..<end], radix: 16), try group.digestsEqual(word) else {
                    throw ProbeError("Qwen TP MTP ranks differ in full request/load identity")
                }
            }
            try nativeError.check()
            let prefixBudget = try QwenTensorParallelMTPPrefixBudget.derive(geometry: profile.geometry,
                maximumTokens: request.maximumTokens, allocationBound: QwenResidentResourceEnvironment.allocationBound)
            let candidates = mtpPrefix?.enabled == true ? QwenTensorParallelMTPPrefixCache.candidates(
                promptCount: request.promptCount, chunkSize: request.chunkSize,
                maximumTokens: prefixBudget.maximumTokens).filter { $0 > 1 } : []
            let prefixScope = loadAgreement + "|" + QwenTensorParallelMTPPrefixBudget.policy
                + "|chunk=\(request.chunkSize)|text|kv=paged"
            let keys = QwenTensorParallelMTPPrefixCache.keys(scope: prefixScope,
                tokens: request.promptTokenIDs, frontiers: candidates)
            var restored: QwenTensorParallelMTPPrefixState?
            if !candidates.isEmpty, let mtpPrefix {
                let offers = mtpPrefix.held(keys: keys, candidates: candidates).map { Int32($0) }
                let votes = try group.exchangeIntegers(offers); try nativeError.check()
                let reused = try QwenTensorParallelMTPPrefixCache.agreed(candidates: candidates, votes: votes.map(Float.init))
                if reused > 0 {
                    guard let key = keys[reused] else { throw ProbeError("Qwen TP MTP prefix key disappeared") }
                    restored = try mtpPrefix.restore(key: key, frontier: reused)
                }
                request = try request.planned(reusedPrefix: reused, splitFinalToken: false)
            }
            let captureFrontier = candidates.last(where: { $0 > request.reusedPrefixTokens }) ?? 0
            let target = try QwenTensorParallelMTPSession(model: model, configuration: admission.configBytes,
                host: mtpHost, request: request, restored: restored?.target)
            // Keep even a target whose assistant construction throws. The
            // enclosing shutdown may clear roots only after checked drain.
            failedMTPTarget = target
            let decoder = try QwenTensorParallelMTPDecoder(target: target, head: mtpHead,
                group: group, depth: mtpTerms.depth, restored: restored,
                captureFrontier: captureFrontier, captureLimitBytes: prefixBudget.captureBytes,
                allocationBound: QwenResidentResourceEnvironment.allocationBound)
            failedMTPDecoder = decoder
            let baseline = Memory.activeMemory
            let watch = QwenDenseStageLoadWatch("Qwen TP MTP request")
            var lastResourceCheck: UInt64 = 0
            func localStop() -> Bool {
                guard (try? control.check(deadline: reserved.deadline)) != nil else { return true }
                let now = DispatchTime.now().uptimeNanoseconds
                if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                    lastResourceCheck = now
                    do {
                        let remaining = try QwenResidentRequestAllowance.continuingRequirement(
                            reservedBytes: reserved.allowance.reservedBytes, additionalBytes: reserved.extraNativeBytes,
                            grownBytes: max(0, Memory.activeMemory - baseline))
                        try QwenResidentResourceEnvironment.requirePower()
                        let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
                            remaining, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
                        guard try watch.admits(QwenDenseStageLoadResources.observeOS(), bytes: remaining,
                            floor: QwenDenseStageLoadPolicy.minimumTrulyFreeBytes), Memory.memoryLimit >= allocator else { return true }
                    } catch { return true }
                }
                return false
            }
            func stopVote(_ clientStopped: Bool = false) throws -> Bool {
                let local = clientStopped || localStop()
                let values = try group.exchangeIntegers(QwenTensorParallelMTPStopVote.contribution(rank: rank, stopped: local))
                try nativeError.check()
                return try QwenTensorParallelMTPStopVote.stopped(values)
            }
            var tokens: [Int] = []
            var finish: ClusterWorkerFinishReason = .clientStop
            var firstLogits: MLXArray?
            var stopped = false
            while target.state.committedTokens < request.promptCount {
                if try stopVote() { stopped = true; break }
                firstLogits = try decoder.prefill(check: { try nativeError.check() }) ?? firstLogits
            }
            func publish(_ token: Int, logprobs: ClusterWorkerTokenLogprobs?) throws -> Bool {
                guard (0..<request.profile.vocabularySize).contains(token), tokens.count < request.outputCount else {
                    throw ProbeError("Qwen TP MTP attempted to publish outside its token allowance")
                }
                tokens.append(token)
                mtpCommittedLogprobs = logprobs
                defer { mtpCommittedLogprobs = nil }
                let wanted = try rank != 0 || onCommittedToken(tokens.count - 1, token, request.promptCount + tokens.count - 1)
                // Every selected token has its own ordinary credit/stop answer,
                // even when several tokens were accepted in one target window.
                let interrupted = try stopVote(!wanted)
                switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(token),
                    committed: tokens.count, outputCount: request.outputCount, wanted: !interrupted) {
                case .eos: finish = .eos; return false
                case .length: finish = .length; return false
                case .clientStop: finish = .clientStop; return false
                case .proceed: return true
                }
            }
            if !stopped, try stopVote() { stopped = true }
            if !stopped {
                guard let firstLogits else { throw ProbeError("Qwen TP MTP prompt did not produce a final row") }
                let full = model.gatheredLogits(firstLogits)
                eval(full); try nativeError.check()
                let sampled = rank == 0 ? (request.sampler?.sample(full) ?? argMax(full, axis: -1)) : nil
                let (selection, flags) = model.broadcastChoice(sampled, stop: 0)
                eval(selection, flags); try nativeError.check()
                let first = Int(selection.item(Int32.self))
                if rank == 0 { request.sampler?.commit(first) }
                try decoder.begin(firstToken: first)
                let firstCapture = rank == 0 ? request.sampler?.takePendingLogprobs() : nil
                var continuing = try publish(first, logprobs: firstCapture)
                while continuing, tokens.count < request.outputCount {
                    if try stopVote() { finish = .clientStop; break }
                    let round = try decoder.step(lastToken: tokens.last!, remaining: request.outputCount - tokens.count,
                        check: { try nativeError.check() })
                    if try stopVote() { finish = .clientStop; break }
                    guard round.logprobs.isEmpty || round.logprobs.count == round.tokens.count else {
                        throw ProbeError("Qwen TP MTP captures do not match accepted target tokens")
                    }
                    for (index, token) in round.tokens.enumerated() {
                        continuing = try publish(token, logprobs: round.logprobs.isEmpty ? nil : round.logprobs[index])
                        if !continuing { break }
                    }
                }
            }
            // Neither rank announces retirement until both target and
            // assistant histories have passed native synchronization locally.
            try decoder.retire()
            guard mtpHost.isDrained else { throw ProbeError("Qwen TP MTP target pages remain retained") }
            let retired = try group.exchangeIntegers(rank == 0 ? [1, 0] : [0, 1])
            try nativeError.check()
            guard retired == [1, 1] else { throw ProbeError("Qwen TP MTP retirement was not bilateral") }
            // Cancellation/deadline remains live through native retirement.
            // Only a bilateral clean-completion boundary can publish a donor.
            let stoppedAtRetirement = try stopVote(finish == .clientStop || stopped)
            let donor = try decoder.takeCapturedPrefix()
            if !stoppedAtRetirement, let donor, let key = keys[donor.committedTokens], let mtpPrefix,
               mtpPrefix.insert(key: key, state: donor) {
                log("darkbloom-tp-mtp-prefix-v1 rank=\(rank) event=insert tokens=\(donor.committedTokens) resident_bytes=\(mtpPrefix.bytesInUse)")
            }
            log("darkbloom-tp-mtp-prefix-v1 rank=\(rank) event=restore tokens=\(request.reusedPrefixTokens) resident_bytes=\(mtpPrefix?.bytesInUse ?? 0)")
            failedMTPDecoder = nil; failedMTPTarget = nil
            log("darkbloom-tensor-parallel-mtp-request-v1 rank=\(rank) request=\(request.requestID.uuidString.lowercased())"
                + " prompt=\(request.promptCount) output=\(tokens.count) finish=\(finish.rawValue) kv_backend=paged "
                + decoder.statistics.diagnosticFields.joined(separator: " "))
            try control.check(deadline: reserved.deadline)
            return .init(requestID: request.requestID, finishReason: finish, selectedTokenIDs: tokens,
                completedFrames: tokens.count, committedTokens: request.promptCount + tokens.count,
                tokenChainSHA256: sha256(try canonicalJSONData(tokens.map(String.init))), bothRequestStatesRetired: true)
        }
    }
}
