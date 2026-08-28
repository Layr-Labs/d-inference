import XCTest
import Crypto
import Foundation
import ProviderCoreFoundation
@testable import darkbloom_publish

/// Coverage for the `darkbloom-publish extract-template` republish flow:
/// golden byte-exact extraction from both tokenizer_config shapes, the
/// rejection gates (strftime_now, already-has-template, missing key, list
/// without default), and the full-command integration including the
/// TemplateRenderCheck gate and digests-only manifest derivation.
final class ExtractTemplateCommandTests: XCTestCase {

    // MARK: - Fixtures

    /// Healthy ChatML-style template (mirrors TemplateRenderCheckTests) —
    /// renders every canonical fixture for a text-only model.
    private let chatMLTemplate = """
        {%- for message in messages -%}
        {{ '<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>\\n' }}
        {%- endfor -%}
        {%- if add_generation_prompt -%}{{ '<|im_start|>assistant\\n' }}{%- endif -%}
        """

    /// Incident-class template (mirrors TemplateRenderCheckTests): compiles,
    /// renders plain chats, but crashes while declaring tools — must be
    /// caught by the render self-check gate.
    private let incidentClassTemplate = """
        {%- if tools -%}
            {%- for tool in tools -%}
                {{ tool['function']['response']['type'] | upper }}
            {%- endfor -%}
        {%- endif -%}
        {%- for message in messages -%}
            {%- if message['content'] is string -%}{{ message['role'] }}: {{ message['content'] }}
            {%- endif -%}
        {%- endfor -%}
        """

    private let textConfigJSON = #"{"model_type": "qwen3"}"#

    /// Raw tokenizer_config JSON exercising JSON escapes: \n, \", \t, a
    /// unicode escape (\u00e9 = é), and a literal multi-byte character.
    private let escapedTokenizerConfigJSON = """
        {"bos_token": "<s>", "chat_template": "{{ bos_token }}caf\\u00e9 says \\"hi\\"\\nline2\\ttab ✓"}
        """

    /// The exact decoded template string the escaped fixture must produce.
    private let escapedTemplateExpected = "{{ bos_token }}café says \"hi\"\nline2\ttab ✓"

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-template-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A realistic old manifest: config/tokenizer artifacts plus two weight
    /// shards that will never exist on local disk (digests-only derivation).
    private func makeOldManifest(
        modelID: String = "mlx-community/test-model",
        version: String = "2026-05-25-r1",
        extraFiles: [ManifestFile] = []
    ) -> ModelManifest {
        var files = [
            ManifestFile(path: "config.json", sizeBytes: 100,
                         sha256: String(repeating: "1a", count: 32), role: "config"),
            ManifestFile(path: "model-00001-of-00002.safetensors", sizeBytes: 5_000_000_000,
                         sha256: String(repeating: "2b", count: 32), role: "weight"),
            ManifestFile(path: "model-00002-of-00002.safetensors", sizeBytes: 4_000_000_000,
                         sha256: String(repeating: "3c", count: 32), role: "weight"),
            ManifestFile(path: "tokenizer.json", sizeBytes: 2000,
                         sha256: String(repeating: "4d", count: 32), role: "tokenizer"),
            ManifestFile(path: "tokenizer_config.json", sizeBytes: 300,
                         sha256: String(repeating: "5e", count: 32), role: "tokenizer"),
        ] + extraFiles
        files.sort { $0.path < $1.path }
        let aggregate = WeightHasher.aggregateFromDigests(
            files.map { (path: $0.path, sha256Hex: $0.sha256) })!
        return ModelManifest(
            schemaVersion: 1,
            modelID: modelID,
            version: version,
            r2Prefix: "v2/\(ManifestBuilder.safeModelID(modelID))/\(version)",
            aggregateSHA256: aggregate,
            totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes },
            fileCount: files.count,
            files: files,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func writeManifest(_ manifest: ModelManifest, to dir: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let url = dir.appendingPathComponent("manifest.old.json")
        try encoder.encode(manifest).write(to: url)
        return url
    }

    /// Run the full command against an artifacts dir + old manifest; returns
    /// the decoded new manifest and the paths of the written outputs.
    @discardableResult
    private func runCommand(
        oldManifest: ModelManifest,
        artifactsDir: URL,
        newVersion: String = "2026-07-23-r2"
    ) async throws -> (manifest: ModelManifest, templateOut: URL, manifestOut: URL) {
        let workDir = try makeTempDir("out")
        let manifestURL = try writeManifest(oldManifest, to: workDir)
        let templateOut = workDir.appendingPathComponent("chat_template.jinja")
        let manifestOut = workDir.appendingPathComponent("manifest.new.json")

        var cmd = try ExtractTemplateCommand.parse([
            "--manifest", manifestURL.path,
            "--artifacts-dir", artifactsDir.path,
            "--new-version", newVersion,
            "--output", manifestOut.path,
            "--template-output", templateOut.path,
        ])
        try await cmd.run()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let newManifest = try decoder.decode(ModelManifest.self, from: Data(contentsOf: manifestOut))
        return (newManifest, templateOut, manifestOut)
    }

    // MARK: - Golden extraction (pure)

    func testExtractStringFormExactBytes() throws {
        let template = try TemplateExtraction.extractTemplate(
            fromTokenizerConfig: Data(escapedTokenizerConfigJSON.utf8))
        XCTAssertEqual(template, escapedTemplateExpected)
        XCTAssertEqual(Data(template.utf8), Data(escapedTemplateExpected.utf8),
                       "extracted template must be byte-exact after UTF-8 encoding")
    }

    func testExtractSurrogatePairsAndCombiningMarksExactBytes() throws {
        // \ud83d\ude00 is the UTF-16 surrogate pair for U+1F600 (😀, UTF-8
        // F0 9F 98 80); "e\u0301" is decomposed e + COMBINING ACUTE ACCENT and
        // must survive WITHOUT NFC normalization (65 CC 81, not C3 A9).
        let json = #"{"chat_template": "hi \ud83d\ude00 e\u0301"}"#
        let template = try TemplateExtraction.extractTemplate(
            fromTokenizerConfig: Data(json.utf8))
        XCTAssertEqual(
            [UInt8](Data(template.utf8)),
            [0x68, 0x69, 0x20, 0xF0, 0x9F, 0x98, 0x80, 0x20, 0x65, 0xCC, 0x81],
            "surrogate pairs must decode to exact UTF-8 and combining marks must not be normalized")
    }

    func testExtractArrayFormTakesDefaultEntry() throws {
        // "default" is deliberately NOT the first entry.
        let json = """
            {"chat_template": [
                {"name": "tool_use", "template": "TOOL-TEMPLATE"},
                {"name": "default", "template": "caf\\u00e9 \\"quoted\\"\\nDEFAULT-TEMPLATE"}
            ]}
            """
        let template = try TemplateExtraction.extractTemplate(fromTokenizerConfig: Data(json.utf8))
        XCTAssertEqual(template, "café \"quoted\"\nDEFAULT-TEMPLATE")
    }

    func testExtractArrayWithoutDefaultIsRejected() {
        let json = #"{"chat_template": [{"name": "tool_use", "template": "T"}]}"#
        XCTAssertThrowsError(
            try TemplateExtraction.extractTemplate(fromTokenizerConfig: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? TemplateExtraction.Error, .chatTemplateArrayWithoutDefault)
        }
    }

    func testExtractMissingChatTemplateKeyIsRejected() {
        let json = #"{"bos_token": "<s>"}"#
        XCTAssertThrowsError(
            try TemplateExtraction.extractTemplate(fromTokenizerConfig: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? TemplateExtraction.Error, .chatTemplateKeyMissing)
        }
    }

    func testExtractEmptyTemplateIsRejected() {
        XCTAssertThrowsError(
            try TemplateExtraction.extractTemplate(
                fromTokenizerConfig: Data(#"{"chat_template": ""}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? TemplateExtraction.Error, .chatTemplateEmpty)
        }
    }

    func testExtractUnsupportedShapeIsRejected() {
        XCTAssertThrowsError(
            try TemplateExtraction.extractTemplate(
                fromTokenizerConfig: Data(#"{"chat_template": 42}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? TemplateExtraction.Error, .chatTemplateUnsupportedShape)
        }
    }

    // MARK: - Rejection gates (pure)

    func testStrftimeNowIsRejected() {
        XCTAssertThrowsError(
            try TemplateExtraction.validateDeterministic(
                template: #"{{ strftime_now("%Y-%m-%d") }} rest of template"#)
        ) { error in
            XCTAssertEqual(error as? TemplateExtraction.Error, .dynamicDateTemplate)
        }
        XCTAssertNoThrow(try TemplateExtraction.validateDeterministic(template: chatMLTemplate))
    }

    func testManifestAlreadyHasTemplateIsRejected() {
        let old = makeOldManifest(extraFiles: [
            ManifestFile(path: "chat_template.jinja", sizeBytes: 10,
                         sha256: String(repeating: "6f", count: 32), role: "template")
        ])
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(old)) { error in
            XCTAssertEqual(
                error as? TemplateExtraction.Error,
                .manifestAlreadyHasTemplate(modelID: "mlx-community/test-model"))
        }

        // Case-insensitive, like the coordinator's duplicate-path check.
        let mixedCase = makeOldManifest(extraFiles: [
            ManifestFile(path: "Chat_Template.jinja", sizeBytes: 10,
                         sha256: String(repeating: "6f", count: 32), role: "other")
        ])
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(mixedCase)) { error in
            XCTAssertEqual(
                error as? TemplateExtraction.Error,
                .manifestAlreadyHasTemplate(modelID: "mlx-community/test-model"))
        }
    }

    func testTraversalAndDuplicatePathsAreRejected() {
        let traversal = makeOldManifest(extraFiles: [
            ManifestFile(path: "../escape.json", sizeBytes: 1,
                         sha256: String(repeating: "7a", count: 32), role: "other")
        ])
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(traversal)) { error in
            XCTAssertEqual(
                error as? TemplateExtraction.Error, .invalidManifestFilePath("../escape.json"))
        }

        let duplicate = makeOldManifest(extraFiles: [
            ManifestFile(path: "CONFIG.json", sizeBytes: 1,
                         sha256: String(repeating: "8b", count: 32), role: "other")
        ])
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(duplicate)) { error in
            guard case .duplicateManifestFilePath? = error as? TemplateExtraction.Error else {
                return XCTFail("expected duplicateManifestFilePath, got \(error)")
            }
        }
    }

    func testInternallyInconsistentManifestIsRejected() {
        // Same digest-trust rationale as the coordinator's register checks:
        // a manifest whose aggregate/total/count don't match its own file
        // list must never seed a new version.
        let good = makeOldManifest()

        let badAggregate = ModelManifest(
            schemaVersion: good.schemaVersion, modelID: good.modelID, version: good.version,
            r2Prefix: good.r2Prefix, aggregateSHA256: String(repeating: "9", count: 64),
            totalSizeBytes: good.totalSizeBytes, fileCount: good.fileCount,
            files: good.files, createdAt: good.createdAt)
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(badAggregate)) { error in
            guard case .inconsistentManifest? = error as? TemplateExtraction.Error else {
                return XCTFail("expected inconsistentManifest, got \(error)")
            }
        }

        let badCount = ModelManifest(
            schemaVersion: good.schemaVersion, modelID: good.modelID, version: good.version,
            r2Prefix: good.r2Prefix, aggregateSHA256: good.aggregateSHA256,
            totalSizeBytes: good.totalSizeBytes, fileCount: good.fileCount + 1,
            files: good.files, createdAt: good.createdAt)
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(badCount))

        let badTotal = ModelManifest(
            schemaVersion: good.schemaVersion, modelID: good.modelID, version: good.version,
            r2Prefix: good.r2Prefix, aggregateSHA256: good.aggregateSHA256,
            totalSizeBytes: good.totalSizeBytes + 1, fileCount: good.fileCount,
            files: good.files, createdAt: good.createdAt)
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(badTotal))

        XCTAssertNoThrow(try TemplateExtraction.validateOldManifest(good))
    }

    func testNegativeManifestFileSizeIsRejected() {
        // Mirror of the coordinator's validateManifestFile size check: a
        // negative size would otherwise flow into the new manifest's totals.
        let old = makeOldManifest(extraFiles: [
            ManifestFile(path: "vocab.json", sizeBytes: -1,
                         sha256: String(repeating: "8c", count: 32), role: "tokenizer")
        ])
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(old)) { error in
            guard case .inconsistentManifest? = error as? TemplateExtraction.Error else {
                return XCTFail("expected inconsistentManifest, got \(error)")
            }
        }
    }

    func testUppercaseManifestDigestIsRejected() {
        let old = makeOldManifest(extraFiles: [
            ManifestFile(path: "vocab.json", sizeBytes: 10,
                         sha256: String(repeating: "AB", count: 32), role: "tokenizer")
        ])
        XCTAssertThrowsError(try TemplateExtraction.validateOldManifest(old)) { error in
            XCTAssertEqual(
                error as? TemplateExtraction.Error,
                .invalidManifestFileDigest(path: "vocab.json"))
        }
    }

    // MARK: - Role classification (task requirement)

    func testChatTemplateJinjaRoleIsTemplate() {
        XCTAssertEqual(ModelScanner.roleFor(filename: "chat_template.jinja"), "template")
    }

    // MARK: - Full-command integration

    func testCommandHappyPathBuildsRepublishManifest() async throws {
        let artifacts = try makeTempDir("artifacts")
        try Data(escapedTokenizerConfigJSON.utf8)
            .write(to: artifacts.appendingPathComponent("tokenizer_config.json"))
        try Data(textConfigJSON.utf8).write(to: artifacts.appendingPathComponent("config.json"))

        let old = makeOldManifest()
        let (new, templateOut, _) = try await runCommand(oldManifest: old, artifactsDir: artifacts)

        // Written template is byte-exact — decoded escapes, no trailing newline.
        let writtenBytes = try Data(contentsOf: templateOut)
        XCTAssertEqual(writtenBytes, Data(escapedTemplateExpected.utf8))
        // ... and mirrored into the artifacts dir for the render check.
        XCTAssertEqual(
            try Data(contentsOf: artifacts.appendingPathComponent("chat_template.jinja")),
            Data(escapedTemplateExpected.utf8))

        // Manifest identity: same model id, new version, canonical prefix.
        XCTAssertEqual(new.schemaVersion, 1)
        XCTAssertEqual(new.modelID, old.modelID)
        XCTAssertEqual(new.version, "2026-07-23-r2")
        XCTAssertEqual(
            new.r2Prefix,
            "v2/\(ManifestBuilder.safeModelID(old.modelID))/2026-07-23-r2")

        // Files: old entries preserved verbatim + the new template entry.
        XCTAssertEqual(new.fileCount, old.fileCount + 1)
        XCTAssertEqual(new.files.count, new.fileCount)
        let byPath = Dictionary(uniqueKeysWithValues: new.files.map { ($0.path, $0) })
        for oldFile in old.files {
            XCTAssertEqual(byPath[oldFile.path], oldFile, "old entry must be preserved: \(oldFile.path)")
        }
        let added = try XCTUnwrap(byPath["chat_template.jinja"])
        XCTAssertEqual(added.role, "template")
        XCTAssertEqual(added.sizeBytes, Int64(writtenBytes.count))
        XCTAssertEqual(added.sha256, sha256Hex(writtenBytes))

        // Manifest is sorted by path and internally consistent.
        XCTAssertEqual(new.files.map(\.path), new.files.map(\.path).sorted())
        XCTAssertEqual(new.totalSizeBytes, old.totalSizeBytes + Int64(writtenBytes.count))
        XCTAssertEqual(
            new.aggregateSHA256,
            WeightHasher.aggregateFromDigests(new.files.map { (path: $0.path, sha256Hex: $0.sha256) }))
        XCTAssertNotEqual(new.aggregateSHA256, old.aggregateSHA256)
    }

    func testCommandRejectsRenderCheckFailure() async throws {
        // Incident-class template: compiles, crashes on the tool fixture —
        // the render gate must refuse to ship it.
        let artifacts = try makeTempDir("artifacts")
        let config = try JSONSerialization.data(
            withJSONObject: ["chat_template": incidentClassTemplate])
        try config.write(to: artifacts.appendingPathComponent("tokenizer_config.json"))
        try Data(textConfigJSON.utf8).write(to: artifacts.appendingPathComponent("config.json"))

        do {
            try await runCommand(oldManifest: makeOldManifest(), artifactsDir: artifacts)
            XCTFail("expected render self-check rejection")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("render self-check"),
                "unexpected error: \(error)")
        }
    }

    func testCommandRejectsManifestThatAlreadyHasTemplate() async throws {
        let artifacts = try makeTempDir("artifacts")
        try Data(escapedTokenizerConfigJSON.utf8)
            .write(to: artifacts.appendingPathComponent("tokenizer_config.json"))
        try Data(textConfigJSON.utf8).write(to: artifacts.appendingPathComponent("config.json"))

        let old = makeOldManifest(extraFiles: [
            ManifestFile(path: "chat_template.jinja", sizeBytes: 10,
                         sha256: String(repeating: "6f", count: 32), role: "template")
        ])
        do {
            try await runCommand(oldManifest: old, artifactsDir: artifacts)
            XCTFail("expected already-has-template rejection")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("already has a standalone"),
                "unexpected error: \(error)")
        }
    }

    func testCommandRejectsStrftimeNowTemplate() async throws {
        let artifacts = try makeTempDir("artifacts")
        let config = try JSONSerialization.data(withJSONObject: [
            "chat_template": "{{ strftime_now(\"%Y-%m-%d\") }}\n" + chatMLTemplate
        ])
        try config.write(to: artifacts.appendingPathComponent("tokenizer_config.json"))
        try Data(textConfigJSON.utf8).write(to: artifacts.appendingPathComponent("config.json"))

        do {
            try await runCommand(oldManifest: makeOldManifest(), artifactsDir: artifacts)
            XCTFail("expected strftime_now rejection")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("strftime_now"),
                "unexpected error: \(error)")
        }
    }

    func testCommandRejectsSameVersion() async throws {
        let artifacts = try makeTempDir("artifacts")
        try Data(escapedTokenizerConfigJSON.utf8)
            .write(to: artifacts.appendingPathComponent("tokenizer_config.json"))
        try Data(textConfigJSON.utf8).write(to: artifacts.appendingPathComponent("config.json"))

        do {
            try await runCommand(
                oldManifest: makeOldManifest(version: "2026-07-23-r2"),
                artifactsDir: artifacts,
                newVersion: "2026-07-23-r2")
            XCTFail("expected same-version rejection")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("equals the old manifest version"),
                "unexpected error: \(error)")
        }
    }

    func testCommandRejectsInvalidNewVersion() throws {
        let artifacts = try makeTempDir("artifacts")
        for bad in ["a/b", "", "has space", "../up"] {
            XCTAssertThrowsError(try {
                var cmd = try ExtractTemplateCommand.parse([
                    "--manifest", "/tmp/whatever.json",
                    "--artifacts-dir", artifacts.path,
                    "--new-version", bad,
                    "--output", "/tmp/out.json",
                    "--template-output", "/tmp/out.jinja",
                ])
                try cmd.validate()
            }(), "version \(bad) must be rejected")
        }
    }

    // MARK: - Render-check integration (task requirement)

    func testExtractedTemplatePassesRenderCheckFixture() throws {
        // Minimal valid artifacts dir (mirrors TemplateRenderCheckTests):
        // extracted-template file + tokenizer_config + text config.json.
        let artifacts = try makeTempDir("renderok")
        let config = try JSONSerialization.data(withJSONObject: [
            "bos_token": "<s>",
            "chat_template": chatMLTemplate,
        ])
        try config.write(to: artifacts.appendingPathComponent("tokenizer_config.json"))
        try Data(textConfigJSON.utf8).write(to: artifacts.appendingPathComponent("config.json"))

        let template = try TemplateExtraction.extractTemplate(
            fromTokenizerConfig: Data(contentsOf: artifacts.appendingPathComponent("tokenizer_config.json")))
        XCTAssertEqual(template, chatMLTemplate)
        try Data(template.utf8).write(to: artifacts.appendingPathComponent("chat_template.jinja"))

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: artifacts), true)
    }
}
