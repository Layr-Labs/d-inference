import Foundation
import Testing
@testable import ProviderCore

@Suite("TelemetryClient panic hook")
struct TelemetryClientTests {

    @Test("PanicHook.install is idempotent")
    func panicHookInstallIdempotent() {
        // Calling twice must not throw, leak signal handlers, or change
        // behaviour. We don't actually trigger a signal -- doing so in a
        // test would terminate the test runner.
        PanicHook.install()
        PanicHook.install()
    }
}
