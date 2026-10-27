import XCTest
@testable import DarkbloomClusterRuntime

final class Gemma4MTPDenseProjectionResourceTests: XCTestCase {
    func testSerialHeadAddsFourIndividuallyRoundedRowsAndBindsFingerprint() throws {
        let identity = String(repeating: "a", count: 64)
        func bound(_ n: Int) -> Int { ((n + 16383) / 16384) * 16384 + 16384 }
        let old = try Gemma4MTPRemoteTargetBudget(requestSHA256: identity, maximumFrontier: 143, bound: bound)
        let explicitOld = try Gemma4MTPRemoteTargetBudget(requestSHA256: identity, maximumFrontier: 143,
            serialTargetHead: false, bound: bound)
        let extended = try Gemma4MTPRemoteTargetBudget(requestSHA256: identity, maximumFrontier: 143,
            serialTargetHead: true, bound: bound)
        XCTAssertEqual(old.fingerprint, explicitOld.fingerprint)
        XCTAssertEqual(old.terms, explicitOld.terms)
        let added = extended.terms.filter { $0.name.hasPrefix("serialTargetHead:") }
        XCTAssertEqual(added.map(\.name), (0..<4).map { "serialTargetHead:row\($0)" })
        XCTAssertEqual(added.map(\.logicalBytes), [Int](repeating: 1_048_576, count: 4))
        XCTAssertEqual(added.map(\.allocationBound), [Int](repeating: bound(1_048_576), count: 4))
        XCTAssertEqual(extended.nativeBytes-old.nativeBytes, 4*bound(1_048_576))
        XCTAssertEqual(extended.terms.filter { !$0.name.hasPrefix("serialTargetHead:") }, old.terms)
        XCTAssertNotEqual(extended.fingerprint, old.fingerprint)
        XCTAssertEqual(extended.hostBytes, old.hostBytes)
    }
}
