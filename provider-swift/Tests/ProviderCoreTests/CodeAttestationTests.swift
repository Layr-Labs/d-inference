import Foundation
import Testing
@testable import ProviderCore

// A code-identity push can land before ProviderLoop installs its handler (the
// coordinator pushes once per connection, no provider-side retry). The bridge
// must buffer such a push and flush it when the handler arrives, or the provider
// stays un-attested. Verifies the fix for the early-push drop.
@Test func apnsBridgeBuffersPushUntilHandlerInstalled() {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
    let bridge = APNsBridge.shared
    let got = Collector()
    func epk(_ m: String) -> [String: Any] {
        ["code_challenge": ["ephemeral_public_key": m, "ciphertext": "x"]]
    }

    // Push BEFORE any handler → must be buffered, not dropped.
    let early = "early-\(UUID().uuidString)"
    bridge.deliverPush(epk(early))

    // Install handler → buffered push flushes to it synchronously.
    bridge.setPushHandler { userInfo in
        if let cc = userInfo["code_challenge"] as? [String: Any],
           let m = cc["ephemeral_public_key"] as? String {
            got.add(m)
        }
    }
    #expect(got.all().contains(early))

    // Push AFTER the handler is installed → straight through.
    let live = "live-\(UUID().uuidString)"
    bridge.deliverPush(epk(live))
    #expect(got.all().contains(live))

    // Reset the shared handler so the singleton doesn't leak into other paths.
    bridge.setPushHandler { _ in }
}

@Test func extractCodeChallengeParsesPushPayload() throws {
    let userInfo: [String: Any] = [
        "aps": ["content-available": 1],
        "code_challenge": ["ephemeral_public_key": "ZXBo", "ciphertext": "Y2lwaA=="],
    ]
    let cc = ProviderLoop.extractCodeChallenge(userInfo)
    #expect(cc?.ephemeralPublicKey == "ZXBo")
    #expect(cc?.ciphertext == "Y2lwaA==")

    // Missing code_challenge → nil (the handler then no-ops, fail-closed).
    #expect(ProviderLoop.extractCodeChallenge(["aps": ["content-available": 1]]) == nil)
}
