import Foundation
import Testing
@testable import ProviderCore

/// 0.10.8 on a pair: the follower's refusal told the person to run `darkbloom stop`, which on a paired Mac stops the pair
/// and leaves the single-Mac provider serving.
@Suite("Single-Mac serving blocking a pair: the guidance")
struct SoloServingGuidanceTests {
    @Test("the cluster worker's refusal names the single-Mac provider and `stop --solo`")
    func refusalSaysStopSolo() {
        let text = DistributedInstalledProviderExclusion.Refusal(processIdentifier: 2282).description
        let cli = BuildEnvironment.current.cliName
        #expect(text.contains("process 2282"), "\(text)")
        #expect(text.contains("`\(cli) stop --solo` on this Mac"), "\(text)")
        #expect(!text.contains("`\(cli) stop`"), "\(text)")
        // The incident classifier still files it as local_provider_running.
        #expect(text.contains("provider instance lock"), "\(text)")
    }
}
