import Testing
@testable import DarkbloomClusterRuntime

// A rank's runs of a tensor divided on an inner axis are read together where they share pages, with the same
// bytes. CPU fixture, no model. The same check runs in `Tests/CheckpointChecks/run.sh`.

@Suite("Checkpoint runs that share pages are read together (CPU fixture)")
struct CheckpointStridedReadTests {
    @Test func runsThatSharePagesAreReadTogether() throws {
        try CheckpointStridedReadCheck.run()
    }
}
