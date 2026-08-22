import Foundation
import XCTest

@testable import ProviderCoreFoundation

/// Cross-language golden vector shared with the coordinator manifest validator.
final class GoldenVectorTest: XCTestCase {
    private struct FixtureCorpus: Decodable {
        let schemaVersion: Int
        let cases: [FixtureCase]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case cases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: container,
                    debugDescription: "unsupported model-manifest fixture schema \(schemaVersion)")
            }
            cases = try container.decode([FixtureCase].self, forKey: .cases)
            let names = Set(cases.map(\.name))
            guard !cases.isEmpty,
                  names.count == cases.count,
                  cases.allSatisfy({ !$0.name.isEmpty && !$0.sourceDirectory.isEmpty })
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .cases,
                    in: container,
                    debugDescription: "model-manifest fixtures require unique named cases and source directories")
            }
        }
    }

    private struct FixtureCase: Decodable {
        let name: String
        let sourceDirectory: String
        let expectedManifest: ModelManifest

        enum CodingKeys: String, CodingKey {
            case name
            case sourceDirectory = "source_directory"
            case expectedManifest = "expected_manifest"
        }
    }

    func testGoldenVector() async throws {
        let root = fixtureRoot()
        let corpus = try decodeCorpus(Data(
            contentsOf: root.appendingPathComponent("expected_manifest.json")))

        for fixture in corpus.cases {
            let expected = fixture.expectedManifest
            let actual = try await ManifestBuilder.build(
                modelDirectory: root.appendingPathComponent(
                    fixture.sourceDirectory, isDirectory: true),
                modelID: expected.modelID,
                version: expected.version)

            let normalized = ModelManifest(
                schemaVersion: actual.schemaVersion,
                modelID: actual.modelID,
                version: actual.version,
                r2Prefix: actual.r2Prefix,
                aggregateSHA256: actual.aggregateSHA256,
                totalSizeBytes: actual.totalSizeBytes,
                fileCount: actual.fileCount,
                files: actual.files,
                createdAt: expected.createdAt)
            XCTAssertEqual(normalized, expected, fixture.name)
        }
    }

    func testFixtureSchemaVersionFailsClosed() {
        for encoded in [
            #"{"cases":[]}"#,
            #"{"schema_version":2,"cases":[]}"#,
        ] {
            XCTAssertThrowsError(try decodeCorpus(Data(encoded.utf8)))
        }
    }

    private func decodeCorpus(_ data: Data) throws -> FixtureCorpus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FixtureCorpus.self, from: data)
    }

    private func fixtureRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("fixtures/model-manifest/v1", isDirectory: true)
    }
}
