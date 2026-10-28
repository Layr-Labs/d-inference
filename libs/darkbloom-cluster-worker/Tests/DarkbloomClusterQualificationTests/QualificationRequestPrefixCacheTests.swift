import Foundation
import XCTest
@testable import DarkbloomClusterQualification
import DarkbloomClusterProtocol

/// A qualification request's own prompt-prefix partition (`pair-check request
/// --request-prefix-cache`): absent by default, `disabled`, or a tenant's
/// digest, never its salt; the driver reserves with exactly that partition.
final class QualificationRequestPrefixCacheTests: XCTestCase {
    private func request() throws -> QualificationRequest {
        try .init(requestID: UUID(uuidString: "5a6b7c8d-1e2f-4a3b-9c4d-5e6f7a8b9c0d")!, promptTokenIDs: Array(1...40),
                  chunkSize: 16, outputCount: 6, stopTokenIDs: [], promptSource: .init(kind: "tokenIDs", description: "constructed"))
    }

    func testThePartitionIsAbsentByDefaultAndCrossesAsTheReservationsOwn() throws {
        var value = try request()
        XCTAssertNil(value.prefixPartition)
        XCTAssertFalse(String(decoding: try value.encoded(), as: UTF8.self).contains("prefixCache"))
        value.prefixCache = "disabled"
        try value.validate()
        XCTAssertEqual(value.prefixPartition, .disabled)
        let salt = "qualification-tenant"
        value.prefixCache = QualificationRequest.prefixCache(tenantSalt: salt)
        try value.validate()
        XCTAssertEqual(value.prefixPartition, .tenant(ClusterWorkerPrefixCache.tenantDigest(salt: salt)))
        let encoded = try value.encoded()
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(salt))
        XCTAssertEqual(try JSONDecoder().decode(QualificationRequest.self, from: encoded).prefixPartition, value.prefixPartition)
    }

    func testAnythingButDisabledOrATenantDigestIsRefused() throws {
        let digest = ClusterWorkerPrefixCache.tenantDigest(salt: "x")
        for bad in ["off", "enabled", "tenant:", "tenant:" + digest.uppercased(), "tenant:" + digest.dropLast(),
                    "tenant:" + digest + "0", "tenant:raw-salt", digest] {
            var value = try request()
            value.prefixCache = bad
            XCTAssertThrowsError(try value.validate(), bad)
        }
    }
}
