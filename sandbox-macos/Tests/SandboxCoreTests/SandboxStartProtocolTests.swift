import Foundation
import SandboxCore
import XCTest

final class SandboxStartProtocolTests: XCTestCase {
    func testStartCarriesFenceRotationAndRejectsResourceMutation() throws {
        let frame = Data(#"{"type":"sandbox_start","protocol_version":1,"host_id":"00000000-0000-0000-0000-000000000001","connection_epoch":"00000000-0000-0000-0000-000000000002","sequence":3,"payload":{"operation_id":"00000000-0000-0000-0000-000000000003","scope":{"sandbox_id":"00000000-0000-0000-0000-000000000004","generation":1,"fencing_token":2},"requested_fencing_token":3,"lease_expires_at":"2026-09-13T20:00:00Z"}}"#.utf8)
        guard case .start(let envelope) = try SandboxControlCodec.decodeCoordinatorMessage(frame) else {
            return XCTFail("expected start operation")
        }
        XCTAssertEqual(envelope.payload.scope.fencingToken.rawValue, 2)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? NSDictionary,
            try JSONSerialization.jsonObject(with: frame) as? NSDictionary
        )
        for extra in [#""base_image_id":"other""#, #""resources":{}"#] {
            let modified = String(decoding: frame, as: UTF8.self).replacingOccurrences(
                of: #""payload":{"operation_id""#,
                with: #""payload":{"# + extra + #", "operation_id""#
            )
            XCTAssertThrowsError(try SandboxControlCodec.decodeCoordinatorMessage(Data(modified.utf8)))
        }
    }
}
