import Foundation
import Network
import Testing
@testable import ProviderCore

@Suite struct NativePairIntentWriterTests {
    @Test func intentUsesOriginalWriterAndCancellationCannotPublishAfterSignerReturns() async throws {
        let signer = MemberFixtureSigner(); signer.pause(onCall: 1)
        let connection = NativePairMemberConnection(nonce: String(repeating: "a", count: 64),
            connection: .init(host: "127.0.0.1", port: 9, using: .tcp), signer: signer, onInvalidation: { _ in })
        let intent = try NativePairIntent(clusterID: "fixture", approvalID: "policy", policySHA256: Data(repeating: 1, count: 32),
            memberIDs: ["a", "b"], signerSHA256: [Data(repeating: 2, count: 32), Data(repeating: 3, count: 32)], rank: 0)
        let task = Task.detached { try connection.sendIntent(intent, until: DispatchTime.now().uptimeNanoseconds + 2_000_000_000) }
        defer { signer.resume(); connection.invalidate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !signer.isPaused && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(signer.isPaused)
        // This is the same writer held by a configuration signature, not a new
        // queue or sequence space beside ordinary grant responses.
        #expect(throws: NativePairMemberError.self) {
            try connection.send(type: "native_pair_cancel", epoch: String(repeating: "b", count: 32), generation: 1,
                payload: Data([68,66,78,67,1]), until: DispatchTime.now().uptimeNanoseconds + 30_000_000)
        }
        #expect(!connection.isLive)
        task.cancel(); signer.resume()
        await #expect(throws: NativePairMemberError.self) { try await task.value }
        #expect(!connection.isLive)
    }
}
