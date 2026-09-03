import Foundation
import Testing
@testable import ProviderCore

private let requiredProtocolFixtureFamilies: Set<String> = [
    "register_heartbeat",
    "backend_slot_kv",
    "inference",
    "attestation",
    "model_lifecycle",
    "prefix_cache_v2",
    "tool_constraints",
]

@Test func sharedProviderMessageContractCorpus() throws {
    let corpus = try decodeProtocolFixtureCorpus(
        Data(contentsOf: protocolFixtureURL()))
    var caseIDs = Set<String>()
    var families = Set<String>()

    for fixture in corpus.cases {
        #expect(!fixture.id.isEmpty)
        #expect(caseIDs.insert(fixture.id).inserted)
        #expect(!fixture.families.isEmpty)
        families.formUnion(fixture.families)

        let source = fixture.message.toFoundation()
        let sourceData = try JSONSerialization.data(
            withJSONObject: source, options: [.sortedKeys, .withoutEscapingSlashes])
        let reencoded: Data
        switch fixture.direction {
        case "provider_to_coordinator":
            let message = try ProviderProtocolCodec.decodeProviderMessage(from: sourceData)
            reencoded = try ProviderProtocolCodec.encodeProviderMessage(message)
        case "coordinator_to_provider":
            let message = try ProviderProtocolCodec.decodeCoordinatorMessage(from: sourceData)
            reencoded = try ProviderProtocolCodec.encodeCoordinatorMessage(message)
        default:
            Issue.record("unknown fixture direction \(fixture.direction) in \(fixture.id)")
            continue
        }

        try assertProtocolFixtureShape(
            fixture, source: source, reencoded: reencoded)
    }

    #expect(families == requiredProtocolFixtureFamilies)
}

@Test func sharedProviderMessageContractSchemaVersionIsRequired() throws {
    for data in [
        Data(#"{"cases":[]}"#.utf8),
        Data(#"{"schema_version":2,"cases":[]}"#.utf8),
    ] {
        #expect(throws: ProtocolFixtureError.self) {
            _ = try decodeProtocolFixtureCorpus(data)
        }
    }
}

private struct ProtocolFixtureCorpus: Decodable {
    let schemaVersion: Int?
    let cases: [ProtocolFixtureCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private struct ProtocolFixtureCase: Decodable {
    let id: String
    let families: [String]
    let direction: String
    let message: JSONValue
    let nonSharedPaths: [String]
    let absentPaths: [String]

    enum CodingKeys: String, CodingKey {
        case id, families, direction, message
        case nonSharedPaths = "non_shared_paths"
        case absentPaths = "absent_paths"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        families = try container.decode([String].self, forKey: .families)
        direction = try container.decode(String.self, forKey: .direction)
        message = try container.decode(JSONValue.self, forKey: .message)
        nonSharedPaths = try container.decodeIfPresent(
            [String].self, forKey: .nonSharedPaths) ?? []
        absentPaths = try container.decodeIfPresent(
            [String].self, forKey: .absentPaths) ?? []
    }
}

private enum ProtocolFixtureError: Error {
    case missingSchemaVersion
    case unsupportedSchemaVersion(Int)
    case messageIsNotObject(String)
}

private func decodeProtocolFixtureCorpus(_ data: Data) throws -> ProtocolFixtureCorpus {
    let corpus = try JSONDecoder().decode(ProtocolFixtureCorpus.self, from: data)
    guard let schemaVersion = corpus.schemaVersion else {
        throw ProtocolFixtureError.missingSchemaVersion
    }
    guard schemaVersion == 1 else {
        throw ProtocolFixtureError.unsupportedSchemaVersion(schemaVersion)
    }
    return corpus
}

private func protocolFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/protocol/v1/provider_messages.json")
}

private func assertProtocolFixtureShape(
    _ fixture: ProtocolFixtureCase,
    source: Any,
    reencoded: Data
) throws {
    guard var expected = source as? [String: Any] else {
        throw ProtocolFixtureError.messageIsNotObject(fixture.id)
    }
    guard var actual = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any] else {
        throw ProtocolFixtureError.messageIsNotObject(fixture.id)
    }

    for path in fixture.absentPaths {
        if protocolJSONPointer(expected, path: path) != nil {
            Issue.record("fixture \(fixture.id) unexpectedly contains absent path \(path)")
        }
        if let value = protocolJSONPointer(actual, path: path) {
            Issue.record("fixture \(fixture.id) re-encoded absent path \(path): \(value)")
        }
    }
    for path in fixture.nonSharedPaths {
        expected = removingProtocolJSONPointer(expected, path: path) as? [String: Any] ?? expected
        actual = removingProtocolJSONPointer(actual, path: path) as? [String: Any] ?? actual
    }

    if !NSDictionary(dictionary: actual).isEqual(to: expected) {
        let want = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        let got = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
        let wantString = String(decoding: want, as: UTF8.self)
        let gotString = String(decoding: got, as: UTF8.self)
        Issue.record("fixture \(fixture.id) shared shape mismatch; want \(wantString); got \(gotString)")
    }
}

private func protocolJSONPointer(_ root: Any, path: String) -> Any? {
    var current: Any = root
    for component in protocolJSONPointerComponents(path) {
        if let object = current as? [String: Any], let next = object[component] {
            current = next
        } else if let array = current as? [Any],
                  let index = Int(component),
                  array.indices.contains(index)
        {
            current = array[index]
        } else {
            return nil
        }
    }
    return current
}

private func removingProtocolJSONPointer(_ root: Any, path: String) -> Any {
    removingProtocolJSONPointer(
        root, components: ArraySlice(protocolJSONPointerComponents(path)))
}

private func removingProtocolJSONPointer(
    _ root: Any,
    components: ArraySlice<String>
) -> Any {
    guard let component = components.first else { return root }
    let remainder = components.dropFirst()

    if var object = root as? [String: Any] {
        if remainder.isEmpty {
            object.removeValue(forKey: component)
        } else if let child = object[component] {
            object[component] = removingProtocolJSONPointer(child, components: remainder)
        }
        return object
    }
    if var array = root as? [Any],
       let index = Int(component),
       array.indices.contains(index)
    {
        if remainder.isEmpty {
            array[index] = NSNull()
        } else {
            array[index] = removingProtocolJSONPointer(array[index], components: remainder)
        }
        return array
    }
    return root
}

private func protocolJSONPointerComponents(_ path: String) -> [String] {
    guard !path.isEmpty else { return [] }
    return path
        .split(separator: "/", omittingEmptySubsequences: true)
        .map {
            $0.replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
}
