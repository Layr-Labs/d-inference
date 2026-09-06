import Foundation
import Testing
@testable import DarkbloomApp

@Suite("My Macs opaque identity boundary")
struct MyMacsWireDecoderTests {
    @Test("Retired serial fields are ignored even when an old server sends an unexpected shape")
    func ignoresRetiredSerialFields() throws {
        let response = try decode("""
        {"id":"opaque/provider:001","status":"offline","serial_number":{"retired":true},"se_public_key":"shared-key"},
        {"id":"opaque/provider:002","status":"offline","serial_number":"PRIVATE-SERIAL","se_public_key":"shared-key"}
        """)
        #expect(response.providers.allSatisfy { $0.serialNumber == nil })
        let snapshot = try MyMacsSnapshot(providers: response, summary: nil, asOf: .now)
        #expect(snapshot.macs.map(\.providerID) == ["opaque/provider:001", "opaque/provider:002"])
        #expect(Set(snapshot.macs.map(\.id)).count == 2)
        #expect(snapshot.macs.map(\.removalToken) == ["opaque/provider:001", "opaque/provider:002"])
    }

    @Test("A provider ID is required even when legacy hardware identifiers exist")
    func requiresProviderID() throws {
        let response = try decode("""
        {"id":"  ","status":"offline","serial_number":"PRIVATE-SERIAL","se_public_key":"key"}
        """)
        #expect(throws: MyMacsMappingError.missingMachineIdentity(providerID: "  ")) {
            try MyMacsSnapshot(providers: response, summary: nil, asOf: .now)
        }
        #expect(throws: DecodingError.self) {
            try decode("""
            {"status":"offline","serial_number":"PRIVATE-SERIAL","se_public_key":"key"}
            """)
        }
    }

    @Test("Duplicate public IDs fail without using hardware material to distinguish them")
    func duplicateIDsFail() throws {
        let response = try decode("""
        {"id":"same-id","status":"offline","serial_number":"SERIAL-A","se_public_key":"key-a"},
        {"id":"same-id","status":"offline","serial_number":"SERIAL-B","se_public_key":"key-b"}
        """)
        #expect(throws: MyMacsMappingError.duplicateMachineIdentity("provider-id:same-id")) {
            try MyMacsSnapshot(providers: response, summary: nil, asOf: .now)
        }
    }

    @Test("Serials supplied by legacy preview constructors cannot be re-encoded")
    func doesNotEncodeLegacySerials() throws {
        var response = try decode(#"{"id":"opaque-id","status":"offline"}"#)
        response.providers[0].serialNumber = "PRIVATE-SERIAL"
        let bytes = try JSONEncoder().encode(response)
        let json = String(decoding: bytes, as: UTF8.self)
        #expect(!json.contains("serial_number"))
        #expect(!json.contains("PRIVATE-SERIAL"))
    }

    private func decode(_ providers: String) throws -> MyMacsProvidersWireResponse {
        let json = """
        {"providers":[\(providers)],"latest_provider_version":"0.8.1","min_provider_version":"0.7.5",
        "heartbeat_timeout_seconds":90,"challenge_max_age_seconds":360}
        """
        return try MyMacsWireDecoder().decodeProviders(from: Data(json.utf8))
    }
}
