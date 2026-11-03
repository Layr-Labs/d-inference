import Foundation
import Testing
@testable import ProviderCore

/// The real spawn path of `LaunchctlControl`. `launchctl help` prints its
/// usage and exits; it reads and changes no launchd state.
@Suite("launchctl invocation")
struct LaunchctlControlTests {
    @Test("Output and exit status of a real launchctl run are returned")
    func capturesOutputAndStatus() throws {
        let help = try LaunchctlControl.runThrowing(["help"], captureStdout: true)
        #expect(help.succeeded)
        #expect(help.stdout.contains("bootstrap"))
    }

    /// `Process.waitUntilExit()` runs the calling thread's run loop even when,
    /// as here, the child's output has already been read to its end.
    @Test("Waiting for launchctl does not run the calling thread's run loop")
    func callersRunLoopIsLeftAlone() throws {
        let probe = RunLoopServiceProbe()
        defer { probe.cancel() }

        _ = try LaunchctlControl.runThrowing(["help"], captureStdout: true)

        #expect(!probe.runLoopWasServiced)
    }
}
