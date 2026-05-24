import XCTest
@testable import ProviderCoreFoundation

final class IdVersionValidationTests: XCTestCase {

    // MARK: - ManifestBuilder.validateModelID

    func testValidModelIDsAccepted() throws {
        try ManifestBuilder.validateModelID("mlx-community/openai-gpt-oss-20b")
        try ManifestBuilder.validateModelID("acme/llama_3.5-8b")
        try ManifestBuilder.validateModelID("single-segment")
        try ManifestBuilder.validateModelID("a")
    }

    func testInvalidModelIDsRejected() {
        let bad: [String] = [
            "",                                // empty
            "/leading/slash",                  // leading /
            "has..parent",                     // .. segment
            "../escape",                       // .. at start
            "has spaces",                      // space disallowed
            "has\nnewline",                    // newline disallowed
            "weird@symbol",                    // @ disallowed
        ]
        for id in bad {
            XCTAssertThrowsError(try ManifestBuilder.validateModelID(id)) { err in
                guard case ManifestBuilder.Error.invalidModelID = err else {
                    return XCTFail("expected invalidModelID for \(id), got \(err)")
                }
            }
        }
    }

    // MARK: - ManifestBuilder.validateVersion

    func testValidVersionsAccepted() throws {
        try ManifestBuilder.validateVersion("v1")
        try ManifestBuilder.validateVersion("2026-05-23-r1")
        try ManifestBuilder.validateVersion("v1.2.3")
        try ManifestBuilder.validateVersion("a")
    }

    func testInvalidVersionsRejected() {
        let bad: [String] = [
            "",                                // empty
            "has/slash",                       // / disallowed
            "has..segment",                    // .. disallowed
            "/leading",                        // leading /
            "v 1",                             // space
            "v\t1",                            // tab
        ]
        for v in bad {
            XCTAssertThrowsError(try ManifestBuilder.validateVersion(v)) { err in
                guard case ManifestBuilder.Error.invalidVersion = err else {
                    return XCTFail("expected invalidVersion for \"\(v)\", got \(err)")
                }
            }
        }
    }

    // MARK: - End-to-end: build() rejects bad inputs

    func testBuildRejectsEmptyID() async throws {
        let tmp = try makeMinimalFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try await ManifestBuilder.build(modelDirectory: tmp, modelID: "", version: "v1")
            XCTFail("expected build to throw for empty id")
        } catch ManifestBuilder.Error.invalidModelID {
            // ok
        }
    }

    func testBuildRejectsEmptyVersion() async throws {
        let tmp = try makeMinimalFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try await ManifestBuilder.build(modelDirectory: tmp, modelID: "ok/id", version: "")
            XCTFail("expected build to throw for empty version")
        } catch ManifestBuilder.Error.invalidVersion {
            // ok
        }
    }

    func testBuildRejectsParentDirInID() async throws {
        let tmp = try makeMinimalFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try await ManifestBuilder.build(modelDirectory: tmp, modelID: "../etc", version: "v1")
            XCTFail("expected build to throw for .. in id")
        } catch ManifestBuilder.Error.invalidModelID {
            // ok
        }
    }

    func testBuildRejectsSlashInVersion() async throws {
        let tmp = try makeMinimalFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try await ManifestBuilder.build(modelDirectory: tmp, modelID: "ok/id", version: "v1/2")
            XCTFail("expected build to throw for / in version")
        } catch ManifestBuilder.Error.invalidVersion {
            // ok
        }
    }

    private func makeMinimalFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "{}".write(to: url.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 4).write(to: url.appendingPathComponent("model.safetensors"))
        return url
    }
}
