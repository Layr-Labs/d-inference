import Foundation

/// A streamed local request's prompt, from the moment this Mac's engine admits the request until its first token:
/// what the local API says while a long prompt is processed, an SSE comment every `ticker.interval`, which OpenAI
/// clients ignore. Until the engine reports how much of the prompt it has computed, the comment gives only the
/// prompt's size (`: prefill in progress, <total> prompt tokens`); once it has, the count
/// (`: prefill <done>/<total> tokens`). It never shows a count the engine didn't report. No engine reports one while
/// the prompt runs today (mlx-swift-lm's `EngineLoopV2` keeps each row's computed tokens to itself), so a long prompt
/// reads "in progress" until its first token.
///
/// - Only a streamed request on a local API has one: `LocalChatUploadResponder` binds `current` around the call that
///   starts the engine work, where `EngineV2Bridge.submitTokenized` reads it. A request that isn't streamed, and every
///   coordinator request, has none.
/// - Nothing runs per token: one timer per request, from its first frame to its first token. The bridge reports the
///   prompt when the engine admits it (on a pair's API, whose queue comes first, when its engine accepts it) and when
///   the engine says it is done, and ends it at the first token.
/// - The comments are ordinary bytes of the response body: the local router returns this Mac's answer as it is, and a
///   pair member's relay (`ClusterLocalRelay`) passes every byte, so both pass them on unchanged.
final class LocalPrefillProgress: @unchecked Sendable {
    /// The progress of the streamed request whose engine work this task starts (`LocalChatUploadResponder`).
    @TaskLocal static var current: LocalPrefillProgress?

    let ticker: LocalPrefillTicker
    private let lock = NSLock()
    /// The prompt's tokens as the engine counts them; nil until it admits the request.
    private var promptTokens: Int?
    /// The prompt tokens the engine reports computed; nil until it reports any.
    private var computedTokens: Int?
    private var ended = false
    private var timer: Task<Void, Never>?

    init(ticker: LocalPrefillTicker = .standard) { self.ticker = ticker }

    /// The engine admitted the request; its prompt has `promptTokens` tokens.
    func accept(promptTokens: Int) {
        lock.withLock { if !ended { self.promptTokens = max(0, promptTokens) } }
    }

    /// The engine has computed `tokens` of the prompt: never backwards, never past the prompt, and nothing before the
    /// engine accepted the request. Today only `CBv2Request.onPrefillCompleted` reports, with the whole prompt: one
    /// Mac's engine as its first token is sampled, a pair's after the answer.
    func advance(to tokens: Int) {
        lock.withLock {
            guard let promptTokens else { return }
            computedTokens = min(promptTokens, max(computedTokens ?? 0, tokens))
        }
    }

    /// The first token came, or the request ended without one: nothing more is said, and the timer stops.
    func end() {
        let timer = lock.withLock { () -> Task<Void, Never>? in
            ended = true
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
    }

    /// The comment for now; nil before the engine accepted the request and after its first token.
    var comment: String? { lock.withLock { lockedComment() } }

    private func lockedComment() -> String? {
        guard !ended, let promptTokens else { return nil }
        guard let computedTokens else { return ": prefill in progress, \(promptTokens) prompt tokens\n\n" }
        return ": prefill \(computedTokens)/\(promptTokens) tokens\n\n"
    }

    /// Writes the comment with `write` every `ticker.interval` until the first token: one timer, only while the
    /// prompt is processed. None starts when the engine reported no prompt (an engine that doesn't report one) or the
    /// first token already came, so a prompt done within the interval writes nothing. Each comment is written under the
    /// lock `end` takes, so none follows the first token.
    func startComments(write: @escaping @Sendable (String) -> Void) {
        let ticker = ticker
        lock.withLock {
            guard !ended, promptTokens != nil, timer == nil else { return }
            timer = Task { [weak self] in
                while true {
                    do { try await ticker.sleep(ticker.interval) } catch { return }
                    guard let self else { return }
                    let wrote = self.lock.withLock { () -> Bool in
                        guard let line = self.lockedComment() else { return false }
                        write(line)
                        return true
                    }
                    guard wrote else { return }
                }
            }
        }
    }
}

/// How often the local API comments on a prompt in progress, and the clock it waits on (tests drive their own).
struct LocalPrefillTicker: Sendable {
    var interval: Duration = .seconds(5)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let standard = LocalPrefillTicker()
}
