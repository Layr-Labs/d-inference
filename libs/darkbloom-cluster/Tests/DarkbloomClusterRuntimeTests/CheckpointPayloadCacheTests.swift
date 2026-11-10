import Testing
@testable import DarkbloomClusterRuntime

// `bypassTensorPayloadCache` drops the weight files' cached pages before a
// selected loader reads its payload uncached. CPU fixture, no model. The same
// check runs in `Tests/CheckpointChecks/run.sh`.

@Suite("Checkpoint payload reads start from no cached weight pages (CPU fixture)")
struct CheckpointPayloadCacheTests {
    @Test func bypassingThePayloadCacheDropsTheWeightFilesCachedPages() throws {
        try CheckpointPayloadCacheCheck.run()
    }
}
