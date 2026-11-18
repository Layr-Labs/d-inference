import Foundation
import Testing
@testable import ProviderCore

/// A release build serves only over a coordinator connection with TLS: a URL
/// that would connect without it is refused. What already connected with TLS
/// (`wss://`, and `https://`, which the provider has always opened with TLS)
/// keeps working; development and staging builds keep `ws://` for local tests.
@Suite struct CoordinatorTransportPolicyTests {
    @Test(arguments: ["ws://api.darkbloom.dev/ws/provider", "ws://127.0.0.1:8080/ws/provider",
                      "http://api.darkbloom.dev/ws/provider", "WS://localhost/ws/provider",
                      "api.darkbloom.dev/ws/provider", "localhost:8080", "ftp://api.darkbloom.dev", ""])
    func releaseRefusesAnyURLThatWouldConnectWithoutTLS(url: String) {
        #expect(CoordinatorTransportPolicy.refusal(forServingURL: url, environment: .prod) != nil, "\(url)")
        #expect(throws: CoordinatorTransportPolicy.Refusal.self) {
            try CoordinatorTransportPolicy.requireTLS(forServingURL: url, environment: .prod)
        }
    }

    @Test(arguments: ["wss://api.darkbloom.dev/ws/provider", "WSS://api.darkbloom.dev/ws/provider",
                      "https://api.darkbloom.dev/ws/provider", "wss://127.0.0.1:8443/ws/provider"])
    func releaseKeepsEveryURLThatConnectsWithTLS(url: String) throws {
        #expect(CoordinatorTransportPolicy.refusal(forServingURL: url, environment: .prod) == nil, "\(url)")
        try CoordinatorTransportPolicy.requireTLS(forServingURL: url, environment: .prod)
    }

    @Test(arguments: [BuildEnvironment.dev, .staging])
    func developmentBuildsKeepPlainWebSocketsForTests(environment: BuildEnvironment) throws {
        try CoordinatorTransportPolicy.requireTLS(forServingURL: "ws://127.0.0.1:8080/ws/provider", environment: environment)
    }

    @Test func theReleaseDefaultIsTLS() {
        #expect(CoordinatorTransportPolicy.refusal(forServingURL: BuildEnvironment.prod.coordinatorWebSocketURL,
                                                   environment: .prod) == nil)
    }
}
