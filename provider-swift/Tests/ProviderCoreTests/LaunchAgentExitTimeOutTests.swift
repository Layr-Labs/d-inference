// Copyright © 2026 Eigen Labs.
//
// launchd `ExitTimeOut` for the provider job: it must leave a margin past
// the drain bound, or on the stuck-request path launchd's SIGKILL lands
// before the goingAway frame — the read_error-with-inflight outcome the
// drain exists to prevent.

import Foundation
import Testing

@testable import ProviderCore

@Suite("LaunchAgent ExitTimeOut")
struct LaunchAgentExitTimeOutTests {

    /// Timeline with one stuck request: drain bound → force-cancel →
    /// terminal flush (2 s) → goingAway frame handed to the transport
    /// (≤ 500 ms) → teardown. launchd's SIGKILL must land after the frame,
    /// with room for the post-close teardown.
    @Test("ExitTimeOut leaves a margin past the drain bound, the terminal flush and the close frame")
    func exitTimeOutHasMargin() {
        let drain = ProviderLoop.gracefulDrainTimeout.components.seconds
        let flush = ProviderLoop.terminalFlushTimeout.components.seconds
        let close = CoordinatorClient.closeFrameFlushBound.timeInterval
        let exitTimeOut = Double(LaunchAgent.exitTimeOutSeconds)
        #expect(exitTimeOut >= Double(drain + flush) + close + 5,
                "ExitTimeOut \(exitTimeOut) leaves no room past drain \(drain) + flush \(flush) + close \(close)")
        #expect(LaunchAgent.exitTimeOutSeconds
            == Int(ProviderLoop.gracefulDrainTimeout.components.seconds)
                + LaunchAgent.shutdownCloseMarginSeconds)
        // The plist carries the same figure.
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.test", programArguments: ["/bin/true"],
            logPath: "/dev/null", environment: [:])
        #expect(plist["ExitTimeOut"] as? Int == LaunchAgent.exitTimeOutSeconds)
    }
}
