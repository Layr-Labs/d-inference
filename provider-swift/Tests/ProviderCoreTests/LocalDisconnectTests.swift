import Foundation
import NIOEmbedded
import Testing
@testable import ProviderCore

@Suite("Local disconnect ownership")
struct LocalDisconnectTests {
    @Test func removableCallbacksAreOneShotAndLateRegistrationCancels() {
        let scope = LocalRequestCancellationScope()
        let counter = DisconnectCounter()
        let removed = scope.register { counter.increment() }
        removed.remove()
        let active = scope.register { counter.increment() }
        #expect(scope.registrationCount == 1)
        scope.cancel()
        scope.cancel()
        #expect(counter.value == 1)
        #expect(scope.registrationCount == 0)
        let late = scope.register { counter.increment() }
        #expect(counter.value == 2)
        active.remove()
        late.remove()
        #expect(scope.registrationCount == 0)
    }

    @Test func completedKeepAliveRequestsDoNotAccumulateRegistrations() throws {
        let registry = LocalHTTPConnectionCancellationRegistry()
        let channel = EmbeddedChannel()
        let connection = registry.connection(for: channel)
        #expect(registry.connection(for: channel) === connection)
        for _ in 0..<1000 {
            let reused = registry.connection(for: channel)
            #expect(reused === connection)
            var scope: LocalRequestCancellationScope? = reused.makeScope()
            let registration = scope!.register {}
            registration.remove()
            scope = nil
        }
        #expect(connection.requestCount == 0)
        #expect(registry.connectionCount == 1)
        try channel.close().wait()
        channel.embeddedEventLoop.run()
        #expect(registry.connectionCount == 0)
    }

    @Test func resetCancelsOnlyLiveRequestsOnItsOwnConnection() throws {
        let registry = LocalHTTPConnectionCancellationRegistry()
        let firstChannel = EmbeddedChannel(), secondChannel = EmbeddedChannel()
        let first = registry.connection(for: firstChannel)
        let second = registry.connection(for: secondChannel)
        let firstScope = first.makeScope(), secondScope = second.makeScope()
        let firstCount = DisconnectCounter(), secondCount = DisconnectCounter()
        let firstRegistration = firstScope.register { firstCount.increment() }
        let secondRegistration = secondScope.register { secondCount.increment() }
        try firstChannel.close().wait()
        firstChannel.embeddedEventLoop.run()
        #expect(firstCount.value == 1)
        #expect(secondCount.value == 0)
        #expect(registry.connectionCount == 1)
        let lateScope = first.makeScope()
        let late = lateScope.register { firstCount.increment() }
        #expect(firstCount.value == 2)
        secondRegistration.remove()
        try secondChannel.close().wait()
        secondChannel.embeddedEventLoop.run()
        #expect(secondCount.value == 0)
        #expect(registry.connectionCount == 0)
        firstRegistration.remove()
        late.remove()
    }
}

private final class DisconnectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
