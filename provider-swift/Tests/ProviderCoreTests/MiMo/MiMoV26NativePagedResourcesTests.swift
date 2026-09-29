import Foundation
import XCTest
@testable import ProviderCore

/// Host-only existing budget ownership. Not a Metal/engine/physical coverage pass.
final class MiMoV26NativePagedResourcesTests: XCTestCase {
    private func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
            configReserveBytes: 4 << 30, memorySnapshot: {
                .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
            })
    }
    func testOnlyGenuinelyUnboundZeroChargeOwnerCanColdRetire() throws {
        let value = MiMoV26NativePagedResources(transactionID: UUID(), sessionID: UUID(), budget: budget())
        XCTAssertNotNil(value.processOwner.snapshot())
        try value.retireUnusedOwner()
        XCTAssertNil(value.processOwner.snapshot())
        XCTAssertNoThrow(try value.retireUnusedOwner())
    }
    func testRealOutstandingProcessPromiseCannotBeColdRefunded() throws {
        let value = MiMoV26NativePagedResources(transactionID: UUID(), sessionID: UUID(), budget: budget())
        try value.processOwner.replaceCharge(1 << 20)
        XCTAssertThrowsError(try value.retireUnusedOwner())
        XCTAssertEqual(value.processOwner.snapshot()?.chargedBytes, 1 << 20)
        // No native operation exists in this host-only cell. Undo precisely
        // this actual host promise, not a fake native retirement receipt.
        try value.processOwner.replaceCharge(0)
        try value.retireUnusedOwner()
        XCTAssertNil(value.processOwner.snapshot())
    }
}
