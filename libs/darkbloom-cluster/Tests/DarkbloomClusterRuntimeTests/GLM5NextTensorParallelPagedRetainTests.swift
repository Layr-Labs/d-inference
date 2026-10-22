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
        // A 31.5K request's ~0.6 GB free and exactly the cap: kept.
        for free in [585 << 20, cap] {
            #expect(!Runtime.trimsIdleSlabs(capacityBytes: free, freeBytes: free, retainBytes: cap, underPressure: false))
        }
        // The serving case: 3.4 GB of slabs, ~2.5 GB of them held by prefix
        // entries, 0.87 GB free: kept (the cap counts only free capacity).
        #expect(!Runtime.trimsIdleSlabs(capacityBytes: 3_393_302_528, freeBytes: 868_786_176, retainBytes: cap,
            underPressure: false))
        // A 1M request's ~19 GB free, and one byte over the cap: trimmed.
        for free in [19 << 30, cap + 1] {
            #expect(Runtime.trimsIdleSlabs(capacityBytes: free + (1 << 30), freeBytes: free, retainBytes: cap,
                underPressure: false))
        }
        // Under pressure everything goes; an empty pool has nothing to trim.
        #expect(Runtime.trimsIdleSlabs(capacityBytes: 585 << 20, freeBytes: 0, retainBytes: cap, underPressure: true))
        #expect(!Runtime.trimsIdleSlabs(capacityBytes: 0, freeBytes: 0, retainBytes: cap, underPressure: true))
        // A zero cap restores the earlier behaviour: every idle release with free slabs trims.
        #expect(Runtime.trimsIdleSlabs(capacityBytes: 1, freeBytes: 1, retainBytes: 0, underPressure: false))
    }
}
