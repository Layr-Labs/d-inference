import Foundation

/// A streamed local request's prompt, from the moment this Mac's engine accepts the request until its first token:
/// what the local API says while a long prompt is processed, an SSE comment every `ticker.interval`
/// (`: prefill <done>/<total> tokens`), which OpenAI clients ignore. The engine reports into it
/// (`EngineV2Bridge.submitTokenized`: the prompt's tokens when it accepts the request, all of them when it reports the
/// prompt done, the end at the first token); the response writes from it. A request that is not streamed, and a
/// coordinator request, has none.
final class LocalPrefillProgress: @unchecked Sendable {
    /// The progress of the streamed request whose engine work this task prepares (`LocalChatUploadResponder`).
    @TaskLocal static var current: LocalPrefillProgress?

    let ticker: LocalPrefillTicker
    private let lock = NSLock()
    private var total: Int?
    private var done = 0
    private var ended = false
    private var timer: Task<Void, Never>?

    init(ticker: LocalPrefillTicker = .standard) { self.ticker = ticker }

    /// The engine accepted the request; its prompt has `promptTokens` tokens.
    func accept(promptTokens: Int) {
        lock.withLock { if !ended { total = max(0, promptTokens) } }
    }

    /// The engine has computed `tokens` of the prompt.
    func advance(to tokens: Int) {
        lock.withLock { if let total { done = min(total, max(done, tokens)) } }
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
        guard !ended, let total else { return nil }
        return ": prefill \(done)/\(total) tokens\n\n"
    }

    /// Writes the comment with `write` every `ticker.interval` until the first token: one timer, only while the
    /// prompt is processed. None starts when the engine reported no prompt (an engine that doesn't report one) or the
    /// first token already came, so a prompt done within the interval writes nothing. Each comment is written under the
    /// lock `end` takes, so none follows the first token.
    func start(write: @escaping @Sendable (String) -> Void) {
        let ticker = ticker
        lock.withLock {
            guard !ended, total != nil, timer == nil else { return }
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
