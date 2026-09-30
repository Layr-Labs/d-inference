import Foundation
import Testing

@testable import ProviderCore

@Suite("Service reservation request wire compatibility")
struct ServiceReservationRequestProtocolTests {
    @Test(arguments: [Optional("opaque-reservation-independent-of-request"), nil])
    func optionalReservationRoundTrip(serviceReservationID: String?) throws {
        let message = CoordinatorMessage.inferenceRequest(.init(
            requestId: "client-request",
            encryptedBody: .init(ephemeralPublicKey: "key", ciphertext: "body"),
            serviceReservationID: serviceReservationID))
        let data = try ProviderProtocolCodec.encodeCoordinatorMessage(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["request_id"] as? String == "client-request")
        #expect(object["service_reservation_id"] as? String == serviceReservationID)
        #expect(object["serviceReservationID"] == nil)
        if serviceReservationID == nil {
            #expect(object["service_reservation_id"] == nil)
        }
        #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) == message)
    }

    @Test func legacyRequestHasNoReservation() throws {
        let wire = #"{"type":"inference_request","request_id":"legacy","future_field":1}"#
        let message = try ProviderProtocolCodec.decodeCoordinatorMessage(from: wire)
        guard case .inferenceRequest(let request) = message else {
            Issue.record("expected inference request")
            return
        }
        #expect(request.requestId == "legacy")
        #expect(request.serviceReservationID == nil)
    }
}

@Test func serviceReservationReleaseWireRoundTrip() throws {
    let id = "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
    let message = CoordinatorClientCodec.providerMessage(for: .serviceReservationReleased(serviceReservationID: id))
    let data = try JSONEncoder().encode(message)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object.count == 2)
    #expect(object["type"] as? String == "service_reservation_released")
    #expect(object["service_reservation_id"] as? String == id)
    #expect(try JSONDecoder().decode(ProviderMessage.self, from: data) == message)
}
