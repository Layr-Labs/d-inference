import Foundation

/// A streamed local request's prompt, from the moment this Mac's engine accepts the request until its first token.
/// Not yet said: the tests that follow pin what the local API says while a long prompt is processed.
final class LocalPrefillProgress: @unchecked Sendable {
    @TaskLocal static var current: LocalPrefillProgress?

    let ticker: LocalPrefillTicker

    init(ticker: LocalPrefillTicker = .standard) { self.ticker = ticker }

    func accept(promptTokens: Int) {}
    func advance(to tokens: Int) {}
    func end() {}
    var comment: String? { nil }
    func start(write: @escaping @Sendable (String) -> Void) {}
}

/// How often the local API comments on a prompt in progress, and the clock it waits on (tests drive their own).
struct LocalPrefillTicker: Sendable {
    var interval: Duration = .seconds(5)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let standard = LocalPrefillTicker()
}
