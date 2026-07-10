import Foundation
import Testing
@testable import ProviderCore

private struct ProtocolContractFile: Decodable {
    let schemaVersion: Int
    let direction: String
    let cases: [ProtocolContractCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case direction
        case cases
    }
}

private struct ProtocolContractCase: Decodable {
    let name: String
    let messageType: String
    let wire: String
    let exactBytes: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case messageType = "message_type"
        case wire
        case exactBytes = "exact_bytes"
    }
}

@Test func coordinatorProtocolV1ContractFixturesDecodeInSwift() throws {
    let fixture = try loadProtocolContract("coordinator_to_provider.json")
    #expect(fixture.schemaVersion == 1)
    #expect(fixture.direction == "coordinator_to_provider")

    for contract in fixture.cases {
        let decoded = try ProviderProtocolCodec.decodeCoordinatorMessage(from: contract.wire)
        let encoded = try ProviderProtocolCodec.encodeCoordinatorMessage(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["type"] as? String == contract.messageType)
    }
}

@Test func providerProtocolV1ContractInventoryCoversSwiftMessages() throws {
    let fixture = try loadProtocolContract("provider_to_coordinator.json")
    #expect(fixture.schemaVersion == 1)
    #expect(fixture.direction == "provider_to_coordinator")

    let fixtureTypes = Set(fixture.cases.map(\.messageType))
    let requiredTypes: Set<String> = [
        "register",
        "heartbeat",
        "inference_accepted",
        "inference_response_chunk",
        "inference_complete",
        "inference_error",
        "attestation_response",
        "code_attestation_response",
        "load_model_status",
        "prefetch_model_status",
        "models_update",
    ]
    #expect(fixtureTypes == requiredTypes)

    let signed = try #require(
        fixture.cases.first(where: { $0.name == "register_full_raw_attestation" })
    )
    #expect(signed.exactBytes)
    #expect(
        signed.wire.contains(
            #""attestation":{"signature":"sig","attestation":{"z":1,"a":[true,false]}}"#
        )
    )
}

private func loadProtocolContract(_ name: String) throws -> ProtocolContractFile {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 {
        root.deleteLastPathComponent()
    }
    let url = root
        .appendingPathComponent("tests/contracts/protocol/v1")
        .appendingPathComponent(name)
    return try JSONDecoder().decode(ProtocolContractFile.self, from: Data(contentsOf: url))
}
