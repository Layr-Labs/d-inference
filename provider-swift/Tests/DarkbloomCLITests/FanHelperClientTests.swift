import Foundation
import Testing

@testable import darkbloom

/// The client talks to a launchd service name that nothing registers, so no
/// real helper answers and no fan state changes.
@Suite("Fan helper client")
struct FanHelperClientTests {
    private func unregisteredClient() -> FanHelperClient {
        FanHelperClient(machServiceName: "io.darkbloom.fan.test.\(UUID().uuidString)")
    }

    private func expectNoHelper(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected the request to fail without a helper")
        } catch let error as FanHelperClientError {
            switch error {
            case .unavailable, .timedOut:
                break
            case .invalidReply(let detail):
                Issue.record("unexpected reply from an unregistered service: \(detail)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("production uses the helper launchd service")
    func productionServiceName() {
        #expect(FanHelperClient().machServiceName == "io.darkbloom.fan")
    }

    @Test("status fails when no helper is registered")
    func statusWithoutHelper() {
        expectNoHelper { _ = try unregisteredClient().status() }
    }

    @Test("restore Auto fails when no helper is registered")
    func restoreWithoutHelper() {
        expectNoHelper { _ = try unregisteredClient().restoreAutomatic() }
    }

    @Test("client errors have fixed messages")
    func errorDescriptions() {
        #expect(FanHelperClientError.unavailable("gone").description == "fan helper is unavailable: gone")
        #expect(FanHelperClientError.timedOut.description == "fan helper did not reply within 2 seconds")
        #expect(FanHelperClientError.invalidReply("bad").description == "fan helper returned an invalid reply: bad")
    }
}
