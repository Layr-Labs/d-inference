import Foundation
import Testing

@testable import ProviderCore

/// A coordinator's `cancel` may say why it cancelled (`reason`, its bounded cancel cause) and whether it pays for the
/// partial answer sent after the cancel (`paid`). Both are optional: a cancel without them decodes as before, and a
/// Mac that predates them ignores them like any unknown key.
@Suite("Coordinator cancel reason")
struct CoordinatorCancelReasonTests {
    private func cancel(_ json: String) throws -> CoordinatorMessage.Cancel? {
        guard case .cancel(let cancel) = try CoordinatorClientCodec.decodeIncomingMessage(from: json) else {
            return nil
        }
        return cancel
    }

    @Test func theReasonAndWhetherThePartialAnswerIsPaidDecode() throws {
        #expect(try cancel(#"{"type":"cancel","request_id":"r","reason":"client_gone_post","paid":true}"#)
            == .init(requestId: "r", reason: .init(code: "client_gone_post", paid: true)))
        #expect(try cancel(#"{"type":"cancel","request_id":"r","reason":"hedge_loser"}"#)
            == .init(requestId: "r", reason: .init(code: "hedge_loser", paid: false)))
    }

    @Test func aCancelWithoutAReasonDecodesAsBefore() throws {
        #expect(try cancel(#"{"type":"cancel","request_id":"r"}"#) == .init(requestId: "r"))
        #expect(try cancel(#"{"type":"cancel","request_id":"r","reason":""}"#) == .init(requestId: "r"))
        #expect(try cancel(#"{"type":"cancel","request_id":"r","paid":true}"#) == .init(requestId: "r"))
    }

    /// `reason` and `paid` only say why: a wrongly typed one is dropped (a mistyped `paid` reads as unpaid), and the
    /// cancel still stops the request.
    @Test func aMistypedReasonOrPaidKeepsTheCancel() throws {
        #expect(try cancel(#"{"type":"cancel","request_id":"r","reason":5,"paid":true}"#) == .init(requestId: "r"))
        #expect(try cancel(#"{"type":"cancel","request_id":"r","reason":"client_gone_post","paid":"yes"}"#)
            == .init(requestId: "r", reason: .init(code: "client_gone_post", paid: false)))
    }

    @Test func theReasonRoundTrips() throws {
        let given = CoordinatorMessage.cancel(.init(requestId: "r", reason: .init(code: "late_content", paid: false)))
        let data = try JSONEncoder().encode(given)
        #expect(try JSONDecoder().decode(CoordinatorMessage.self, from: data) == given)
        let plain = try JSONEncoder().encode(CoordinatorMessage.cancel(.init(requestId: "r")))
        let object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(Set(object.keys) == ["type", "request_id"], "no reason, no new keys")
    }
}
