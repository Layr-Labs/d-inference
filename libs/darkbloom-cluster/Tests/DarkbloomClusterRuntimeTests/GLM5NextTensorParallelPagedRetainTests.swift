import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// Model-free: an idle GLM tensor-parallel rank keeps its page slabs for the
// next request up to `DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB` (default 2,048 MB
// per rank) and trims them above it, or under host pressure, so memory drops
// after a long generation.
@Suite("GLM tensor-parallel idle page slabs: retention cap")
struct GLM5NextTensorParallelPagedRetainTests {
    typealias Runtime = GLM5NextTensorParallelResidentRuntime

    @Test func theCapIsTwoGigabytesUnlessNamed() throws {
        #expect(try Runtime.pagedRetainBytes([:]) == 2048 << 20)
        #expect(try Runtime.pagedRetainBytes(["DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB": "512"]) == 512 << 20)
        #expect(try Runtime.pagedRetainBytes(["DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB": "0"]) == 0)
        for bad in ["", "-1", "2G", "1.5"] {
            #expect(throws: (any Error).self) {
                _ = try Runtime.pagedRetainBytes(["DARKBLOOM_CLUSTER_GLM_PAGED_RETAIN_MB": bad])
            }
        }
    }

    @Test func slabsAtOrBelowTheCapStayAndAboveItGo() {
        let cap = 2048 << 20
        // A 31.5K request's ~0.6 GB and exactly the cap: kept.
        for capacity in [585 << 20, cap] {
            #expect(!Runtime.trimsIdleSlabs(capacityBytes: capacity, retainBytes: cap, underPressure: false))
        }
        // A 1M request's ~19 GB, and one byte over the cap: trimmed.
        for capacity in [19 << 30, cap + 1] {
            #expect(Runtime.trimsIdleSlabs(capacityBytes: capacity, retainBytes: cap, underPressure: false))
        }
        // Under pressure everything goes; an empty pool has nothing to trim.
        #expect(Runtime.trimsIdleSlabs(capacityBytes: 585 << 20, retainBytes: cap, underPressure: true))
        #expect(!Runtime.trimsIdleSlabs(capacityBytes: 0, retainBytes: cap, underPressure: true))
        // A zero cap restores the earlier behaviour: every idle release trims.
        #expect(Runtime.trimsIdleSlabs(capacityBytes: 1, retainBytes: 0, underPressure: false))
    }
}
