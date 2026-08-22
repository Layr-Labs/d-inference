import Foundation
import Testing
@testable import ProviderCore

@Suite("Telemetry wire symmetry")
struct TelemetrySymmetryTests {
    @Test func telemetryEventJSONSymmetry() throws {
        let data = try telemetryFixtureData()
        let corpus = try decodeTelemetryFixture(data)
        let rawCases = try rawTelemetryCases(in: data)
        #expect(!corpus.cases.isEmpty, "telemetry fixture has no named cases")
        #expect(rawCases.count == corpus.cases.count)
        guard let sampleEvent = corpus.cases.first?.event else {
            throw TelemetryFixtureError.invalidShape
        }
        let eventFieldSets = telemetryEventFieldSets(sampleEvent)
        #expect(eventFieldSets.required == Set(corpus.requiredEventFields.keys))
        #expect(eventFieldSets.optional == Set(corpus.optionalEventFields.keys))

        var declaredFields = corpus.requiredEventFields
        for (field, enabled) in corpus.requiredEventFields {
            #expect(enabled, "required event field \(field) is disabled")
        }
        for (field, enabled) in corpus.optionalEventFields {
            #expect(enabled, "optional event field \(field) is disabled")
            #expect(declaredFields[field] == nil, "event field \(field) is both required and optional")
            declaredFields[field] = enabled
        }

        var names = Set<String>()
        var sawOmissionCase = false
        var sawAllFieldsCase = false
        for (index, fixture) in corpus.cases.enumerated() {
            #expect(!fixture.name.isEmpty, "telemetry fixture name is empty")
            #expect(names.insert(fixture.name).inserted, "duplicate telemetry fixture name \(fixture.name)")

            let encoded = try JSONEncoder().encode(fixture.event)
            guard let actual = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  index < rawCases.count,
                  let expected = rawCases[index]["event"] as? [String: Any]
            else {
                throw TelemetryFixtureError.invalidShape
            }
            #expect(
                NSDictionary(dictionary: actual).isEqual(to: expected),
                "wire JSON mismatch for \(fixture.name)"
            )

            for field in corpus.requiredEventFields.keys {
                #expect(actual[field] != nil, "required field \(field) is missing in \(fixture.name)")
            }
            for field in actual.keys {
                #expect(declaredFields[field] != nil, "undeclared wire field \(field) in \(fixture.name)")
            }
            var omittedFields = Set<String>()
            for field in fixture.omittedKeys {
                #expect(
                    corpus.optionalEventFields[field] != nil,
                    "omitted field \(field) is not declared optional"
                )
                #expect(
                    omittedFields.insert(field).inserted,
                    "omitted field \(field) is duplicated"
                )
                #expect(actual[field] == nil, "optional field \(field) should be omitted in \(fixture.name)")
            }
            for field in corpus.optionalEventFields.keys {
                #expect(
                    (actual[field] == nil) == omittedFields.contains(field),
                    "optional field \(field) omission is not declared by \(fixture.name)"
                )
            }

            guard let source = actual["source"] as? String,
                  let severity = actual["severity"] as? String,
                  let kind = actual["kind"] as? String
            else {
                throw TelemetryFixtureError.invalidShape
            }
            #expect(corpus.vocabularies.sources[source] == true)
            #expect(corpus.vocabularies.severities[severity] == true)
            #expect(corpus.vocabularies.kinds[kind] == true)

            sawOmissionCase = sawOmissionCase || !fixture.omittedKeys.isEmpty
            sawAllFieldsCase =
                sawAllFieldsCase || declaredFields.keys.allSatisfy { actual[$0] != nil }
        }
        #expect(sawOmissionCase, "telemetry fixture must cover optional omission")
        #expect(sawAllFieldsCase, "telemetry fixture must cover every declared event field")
    }

    @Test func telemetryVocabulariesMatch() throws {
        let corpus = try decodeTelemetryFixture(try telemetryFixtureData())
        for (value, enabled) in corpus.vocabularies.sources {
            #expect(enabled, "source vocabulary value \(value) is disabled")
        }
        for (value, enabled) in corpus.vocabularies.severities {
            #expect(enabled, "severity vocabulary value \(value) is disabled")
        }
        for (value, enabled) in corpus.vocabularies.kinds {
            #expect(enabled, "kind vocabulary value \(value) is disabled")
        }

        let sources = Set([
            TelemetrySource.coordinator,
            .provider,
            .app,
            .console,
            .bridge,
        ].map(\.rawValue))
        #expect(sources == Set(corpus.vocabularies.sources.keys))

        let severities = Set([
            TelemetrySeverity.debug,
            .info,
            .warn,
            .error,
            .fatal,
        ].map(\.rawValue))
        #expect(severities == Set(corpus.vocabularies.severities.keys))

        let kinds = Set(TelemetryKind.allCases.map(\.rawValue))
        #expect(kinds == Set(corpus.vocabularies.kinds.keys))
    }

    @Test func telemetryFixtureSchemaVersionIsRequired() {
        for encoded in [
            #"{"cases":[]}"#,
            #"{"schema_version":2,"cases":[]}"#,
        ] {
            var rejected = false
            do {
                _ = try decodeTelemetryFixture(Data(encoded.utf8))
            } catch {
                rejected = true
            }
            #expect(rejected, "missing or unsupported fixture schema was accepted")
        }
    }
}

private struct TelemetryFixtureCorpus: Decodable {
    let schemaVersion: Int
    let vocabularies: TelemetryVocabularies
    let requiredEventFields: [String: Bool]
    let optionalEventFields: [String: Bool]
    let cases: [TelemetryFixtureCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case vocabularies
        case requiredEventFields = "required_event_fields"
        case optionalEventFields = "optional_event_fields"
        case cases
    }
}

private struct TelemetryVocabularies: Decodable {
    let sources: [String: Bool]
    let severities: [String: Bool]
    let kinds: [String: Bool]
}

private struct TelemetryFixtureCase: Decodable {
    let name: String
    let event: TelemetryEvent
    let omittedKeys: [String]

    enum CodingKeys: String, CodingKey {
        case name, event
        case omittedKeys = "omitted_keys"
    }
}

private enum TelemetryFixtureError: Error {
    case invalidShape
    case missingSchemaVersion
    case unsupportedSchemaVersion(Int)
}

private func decodeTelemetryFixture(_ data: Data) throws -> TelemetryFixtureCorpus {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TelemetryFixtureError.invalidShape
    }
    guard let schemaVersion = object["schema_version"] as? Int else {
        throw TelemetryFixtureError.missingSchemaVersion
    }
    guard schemaVersion == 1 else {
        throw TelemetryFixtureError.unsupportedSchemaVersion(schemaVersion)
    }
    return try JSONDecoder().decode(TelemetryFixtureCorpus.self, from: data)
}

private func rawTelemetryCases(in data: Data) throws -> [[String: Any]] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cases = object["cases"] as? [[String: Any]]
    else {
        throw TelemetryFixtureError.invalidShape
    }
    return cases
}

private func telemetryEventFieldSets(
    _ event: TelemetryEvent
) -> (required: Set<String>, optional: Set<String>) {
    var required = Set<String>()
    var optional = Set<String>()
    for property in Mirror(reflecting: event).children {
        guard let label = property.label else { continue }
        let field = telemetryWireFieldName(label)
        if Mirror(reflecting: property.value).displayStyle == .optional {
            optional.insert(field)
        } else {
            required.insert(field)
        }
    }
    return (required, optional)
}

private func telemetryWireFieldName(_ propertyName: String) -> String {
    var fieldName = ""
    for character in propertyName {
        if character.isUppercase {
            fieldName.append("_")
            fieldName.append(contentsOf: String(character).lowercased())
        } else {
            fieldName.append(character)
        }
    }
    return fieldName
}

private func telemetryFixtureData() throws -> Data {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(
        contentsOf: repositoryRoot
            .appendingPathComponent("fixtures/telemetry/v1/events.json")
    )
}
