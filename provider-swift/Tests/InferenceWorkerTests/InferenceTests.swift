import Foundation
import Testing
@testable import ProviderCore
@testable import InferenceWorkerCore

@Test func cancellationRegistryCancelsAndRemovesToken() async {
    let registry = InferenceCancellationRegistry()
    let token = await registry.register(requestId: "req-1")

    #expect(await registry.activeRequestIds == ["req-1"])
    #expect(!token.isCancelled)
    #expect(await registry.cancel(requestId: "req-1"))
    #expect(token.isCancelled)
    #expect(await registry.activeRequestIds.isEmpty)
    #expect(await !registry.cancel(requestId: "req-1"))
}
