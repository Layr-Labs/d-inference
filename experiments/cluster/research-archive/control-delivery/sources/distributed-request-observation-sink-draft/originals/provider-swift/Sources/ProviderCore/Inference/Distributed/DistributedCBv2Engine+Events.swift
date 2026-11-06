import Foundation
import MLXLMCommon

extension DistributedCBv2Engine {
    func receive(_ event: DistributedResidentEvent, state: DistributedRequestState) -> Bool {
        guard active === state, state.terminal == nil else { return false }
        guard readyCapacity() != nil else { return false }
        checkDeadline(state)
        guard state.terminal == nil else { return false }
        switch event {
        case .token(let token):
            guard token >= 0, token < profile.vocabularySize,
                state.completionTokens < state.request.maxTokens
            else {
                stop(state, reason: .error("invalid distributed committed token"))
                return false
            }
            state.completionTokens += 1
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
            if case .terminated = state.continuation.yield(.delta(text: text, tokens: [token], logprobs: nil)) {
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
        case .finished(let reason):
            if reason == .length && state.completionTokens != state.request.maxTokens {
                stop(state, reason: .error("distributed length terminal before output limit"))
            } else if reason == .stop && state.completionTokens == 0 {
                stop(state, reason: .error("distributed stop terminal before any committed token"))
            } else {
                stop(state, reason: reason)
            }
        }
        return state.terminal == nil
    }

    func stop(_ state: DistributedRequestState, reason: CBv2FinishReason) {
        guard active === state else { return }
        // A later peer loss must not preserve an earlier successful terminal.
        // Otherwise retain the first failure/cancellation as the primary cause.
        if state.terminal == nil || state.terminal == .stop || state.terminal == .length {
            let changed = state.terminal != reason
            state.terminal = reason
            if changed { observe(state, phase: .terminal, reason: reason) }
        }
        state.deadlineTask?.cancel()
        // Normal EOS/length/stop-string completion is conveyed by false from
        // emit. The owner performs its clean finish/retirement handshake; native
        // Session.cancel is a failure path and must not be used for this case.
        let needsCancellation = reason != .stop && reason != .length
        if needsCancellation && !state.cancelSent {
            state.cancelSent = true
            state.lease.cancel()
        }
    }

    func checkDeadline(_ state: DistributedRequestState) {
        guard active === state, state.terminal == nil else { return }
        let now = clock.now()
        if now >= state.absoluteDeadline {
            stop(state, reason: .terminal(cause: .safetyDeadline, message: "distributed request deadline"))
        } else if state.completionTokens == 0, let deadline = state.firstTokenDeadline, now >= deadline {
            stop(state, reason: .terminal(cause: .prefillStall, message: "distributed first-token deadline"))
        }
    }

    func armDeadline(_ state: DistributedRequestState) {
        state.deadlineTask?.cancel()
        let deadline: ContinuousClock.Instant
        if state.completionTokens == 0, let first = state.firstTokenDeadline {
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
        guard active === state else { return }
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
        let usage = CBv2Usage(
            promptTokens: state.request.promptTokens.count, completionTokens: state.completionTokens)
        active = nil
        state.continuation.onTermination = nil
        state.continuation.yield(.finished(reason: reason, usage: usage))
        state.continuation.finish()
        observe(state, phase: .retired, reason: reason)
        state.retired.complete()
    }
}
