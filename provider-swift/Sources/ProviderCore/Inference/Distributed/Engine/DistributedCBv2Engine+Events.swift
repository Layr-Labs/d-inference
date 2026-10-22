import Foundation
import MLXLMCommon

extension DistributedCBv2Engine {
    func receive(_ event: DistributedResidentEvent, state: DistributedRequestState) -> Bool {
        guard isActive(state) else { return false }
        // The prefix report arrives after the last token, when the request
        // may already have its terminal; it only feeds usage and receipts.
        if case .promptCache(let reused, let stored) = event {
            let prompt = state.request.promptTokens.count
            if reused >= 0, reused < prompt { state.reusedPromptTokens = reused }
            state.storedPromptFrontiers = stored.filter { $0 > 0 && $0 < prompt }
            return state.terminal == nil
        }
        // Like the prefix report: after the last token, telemetry only.
        if case .telemetry(let value) = event {
            state.rankTelemetry = value
            return state.terminal == nil
        }
        guard state.terminal == nil else {
            // The first token after a clean stop was asked for is the one the
            // stop answers. Nothing is delivered; from here the stop only has
            // to finish, so the first-token deadline no longer applies.
            if event.committedToken != nil, state.cleanStopPending, !state.cleanStopAnswered {
                state.cleanStopAnswered = true
                if !state.cancelSent { armDeadline(state) }
            }
            return false
        }
        guard readyCapacity() != nil else { return false }
        checkDeadline(state)
        guard state.terminal == nil else { return false }
        switch event {
        case .token(let token), .loggedToken(let token, _):
            guard token >= 0, token < profile.vocabularySize,
                state.completionTokens < state.request.maxTokens
            else {
                stop(state, reason: .error("invalid distributed committed token"))
                return false
            }
            state.completionTokens += 1
            let arrived = clock.now()
            if state.firstTokenAt == nil { state.firstTokenAt = arrived }
            state.lastTokenAt = arrived
            let isStop = state.request.stopTokens.contains(token)
            let text = isStop ? "" : state.detokenizer.push([token])
            if clock.now() >= state.absoluteDeadline {
                stop(state, reason: .terminal(cause: .safetyDeadline, message: "distributed request deadline"))
                return false
            }
            if state.completionTokens == 1, let deadline = state.firstTokenDeadline, clock.now() >= deadline {
                stop(state, reason: .terminal(cause: .prefillStall, message: "distributed first-token deadline"))
                return false
            }
            // Raw stop IDs count for usage but never enter the text detokenizer.
            var logprobs: [CBv2TokenLogprob]?
            if case .loggedToken(_, let value) = event { logprobs = [value] }
            if case .terminated = state.continuation.yield(.delta(text: text, tokens: [token], logprobs: logprobs)) {
                stop(state, reason: .cancelled)
                return false
            }
            if state.completionTokens == 1 { observe(state, phase: .firstToken) }
            if isStop || state.detokenizer.matchedStopString {
                stop(state, reason: .stop)
            } else if state.completionTokens == state.request.maxTokens {
                stop(state, reason: .length)
            } else if state.completionTokens == 1 {
                armDeadline(state)
            }
        case .promptCache, .telemetry:
            break
        case .finished(let reason):
            if reason == .cancelled {
                // The owner ended the request with a clean stop of its own
                // (it is stopping). The lease is already finishing: nothing
                // is cancelled, and the output is reported as incomplete.
                stop(state, reason: .cancelled, leaseFinishing: true)
            } else if reason == .length && state.completionTokens != state.request.maxTokens {
                stop(state, reason: .error("distributed length terminal before output limit"))
            } else if reason == .stop && state.completionTokens == 0 {
                stop(state, reason: .error("distributed stop terminal before any committed token"))
            } else {
                stop(state, reason: reason)
            }
        }
        return state.terminal == nil
    }

    /// How a request ends, by reason:
    /// - `.stop`, `.length`: false from emit; the owner performs its clean
    ///   finish/retirement handshake. Native cancel must not be used here.
    /// - `.cancelled` (the consumer went away, or the host is stopping): the
    ///   same clean handshake, asked for through the lease. Both peers retire
    ///   and the owner stays usable. The request's deadlines stay armed and
    ///   are what cancels a request that never reaches a token. A lease that
    ///   has no clean stop is cancelled as before.
    /// - every failure: the lease is cancelled, which is the owner's failure
    ///   path, and the consumer is told at once.
    func stop(_ state: DistributedRequestState, reason: CBv2FinishReason, leaseFinishing: Bool = false) {
        guard isActive(state) else { return }
        // A later peer loss must not preserve an earlier successful terminal.
        // Otherwise retain the first failure/cancellation as the primary cause.
        var changed = false
        if state.terminal == nil || state.terminal == .stop || state.terminal == .length {
            changed = state.terminal != reason
            state.terminal = reason
        }
        switch reason {
        case .stop, .length:
            state.deadlineTask?.cancel()
        case .cancelled where !state.cancelSent
            && (leaseFinishing || state.cleanStopPending || state.lease.requestCleanStop()):
            state.cleanStopPending = true
        default:
            state.deadlineTask?.cancel()
            if !state.cancelSent {
                state.cancelSent = true
                state.lease.cancel()
            }
        }
        // Internal cancellation is armed before best-effort instrumentation.
        if changed { observe(state, phase: .terminal, reason: state.terminal) }
        if changed, case .error(let text) = reason {
            // The cause, bounded, in the leader's log (S24): the owner side's
            // fixed text or a rank's reason code, never prompt or token text.
            clusterObservabilityLog(.warning, "distributed request failed",
                ["generation": String(state.generation.uuidString.lowercased().prefix(8)), "reason": String(text.prefix(300))])
        }
        publishFailure(state)
    }

    /// A failure is final the moment it is known, so the consumer is told then
    /// and not when both peers have retired, which for a peer still inside a
    /// collective can be its whole progress limit later. The lease and every
    /// resource stay owned until retirement. A clean finish is still published
    /// at retirement: a client is not told "done" while the pair is busy. A
    /// request refused before its lease started has no peer to wait for and
    /// keeps the order "retired, released, then told".
    func publishFailure(_ state: DistributedRequestState) {
        guard state.leaseStarted, !state.terminalPublished, let reason = state.terminal else { return }
        switch reason {
        case .stop, .length, .cancelled: return
        default: break
        }
        state.terminalPublished = true
        let usage = CBv2Usage(
            promptTokens: state.request.promptTokens.count, completionTokens: state.completionTokens)
        state.continuation.onTermination = nil
        state.continuation.yield(.finished(reason: reason, usage: usage))
        state.continuation.finish()
    }

    /// Usage with the prefix reuse both peers reported. A hit is billed and
    /// reported as resident memory: the KV never left the ranks.
    static func usage(_ state: DistributedRequestState) -> CBv2Usage {
        let reused = state.reusedPromptTokens
        guard reused > 0 else {
            return CBv2Usage(promptTokens: state.request.promptTokens.count, completionTokens: state.completionTokens)
        }
        return CBv2Usage(promptTokens: state.request.promptTokens.count, completionTokens: state.completionTokens,
            prefixCacheHitTokens: reused, prefixCacheOutcome: .hit, prefixCacheTier: .resident,
            prefixCacheMatchedTokens: reused, prefixCachePrefillTokensSaved: reused)
    }

    func checkDeadline(_ state: DistributedRequestState) {
        guard isActive(state) else { return }
        let now = clock.now()
        guard state.terminal == nil else {
            // A clean stop that has not come by the request's own deadline is
            // given up. From here the request has failed by that deadline:
            // cancelling ends the peers, which a stalled pair needs, and the
            // deadline replaces the cancellation as the reported cause.
            guard state.cleanStopPending, !state.cancelSent else { return }
            let awaitingFirstToken = state.completionTokens == 0 && !state.cleanStopAnswered
            let firstTokenExpired = awaitingFirstToken && (state.firstTokenDeadline.map { now >= $0 } ?? false)
            guard now >= state.absoluteDeadline || firstTokenExpired else { return }
            state.terminal = now >= state.absoluteDeadline
                ? .terminal(cause: .safetyDeadline, message: "distributed request deadline")
                : .terminal(cause: .prefillStall, message: "distributed first-token deadline")
            state.cancelSent = true
            state.lease.cancel()
            observe(state, phase: .terminal, reason: state.terminal)
            publishFailure(state)
            return
        }
        if now >= state.absoluteDeadline {
            stop(state, reason: .terminal(cause: .safetyDeadline, message: "distributed request deadline"))
        } else if state.completionTokens == 0, let deadline = state.firstTokenDeadline, now >= deadline {
            stop(state, reason: .terminal(cause: .prefillStall, message: "distributed first-token deadline"))
        }
    }

    func armDeadline(_ state: DistributedRequestState) {
        state.deadlineTask?.cancel()
        let deadline: ContinuousClock.Instant
        if state.completionTokens == 0, !state.cleanStopAnswered, let first = state.firstTokenDeadline {
            deadline = min(first, state.absoluteDeadline)
        } else {
            deadline = state.absoluteDeadline
        }
        state.deadlineTask = Task { [weak self, weak state] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let self, let state else { return }
            self.onQueue { self.checkDeadline(state) }
        }
    }

    func retire(_ state: DistributedRequestState) {
        guard isActive(state) else { return }
        _ = readyCapacity()
        if state.terminal == nil {
            stop(state, reason: .error("distributed owner retired without a terminal event"))
        }
        state.deadlineTask?.cancel()
        state.lease.releaseResources()
        var reason = state.terminal ?? .error("missing distributed terminal")
        if reason == .stop || reason == .length {
            let tail = state.detokenizer.flush()
            if !tail.isEmpty {
                state.continuation.yield(.delta(text: tail, tokens: [], logprobs: nil))
            }
            if state.detokenizer.matchedStopString { reason = .stop }
        }
        let usage = Self.usage(state)
        if reason == .stop || reason == .length, let receipt = state.request.prefixCacheReceiptID,
           !state.storedPromptFrontiers.isEmpty {
            residentPrefixPublication?(receipt, state.storedPromptFrontiers)
        }
        actives[state.generation] = nil
        state.continuation.onTermination = nil
        if !state.terminalPublished {
            state.continuation.yield(.finished(reason: reason, usage: usage))
            state.continuation.finish()
        }
        state.retired.complete()
        observe(state, phase: .retired, reason: reason)
    }
}
