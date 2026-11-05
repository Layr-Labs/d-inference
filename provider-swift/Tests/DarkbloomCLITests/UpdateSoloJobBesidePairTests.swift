import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// 0.10.7's `darkbloom update` restarted a loaded single-Mac provider job first, and never the pair; the job then took
/// the serving lock the pair's parts need.
@Suite("darkbloom update on a Mac whose pair is started")
struct UpdateSoloJobBesidePairTests {
    @Test("a single-Mac job beside a started pair is left as it is, and the pair restarts")
    func soloJobBesidePair() {
        #expect(Update.soloJobBesidePair(soloJobLoaded: true, pairServes: true))
        #expect(!Update.soloJobBesidePair(soloJobLoaded: true, pairServes: false)) // Single-Mac serving alone: restarted as before.
        #expect(!Update.soloJobBesidePair(soloJobLoaded: false, pairServes: true))
        let lines = Update.soloJobLeftLines.joined(separator: " ")
        #expect(lines.contains("`\(BuildEnvironment.current.cliName) stop --solo`"), "\(lines)")
        #expect(lines.contains("restarts the pair"), "\(lines)")
    }
}
