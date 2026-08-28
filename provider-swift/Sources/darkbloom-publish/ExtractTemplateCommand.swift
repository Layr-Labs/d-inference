import ArgumentParser
import Crypto
import Foundation
import ProviderCoreFoundation

/// Republish helper for models that were published without a standalone
/// `chat_template.jinja` (their template only exists as the `chat_template`
/// field inside tokenizer_config.json). The provider's SSD prefix cache
/// (`PromptContractIdentity`) hard-requires the standalone file, so those
/// models report `cache_init_failed` until republished.
///
/// This subcommand extracts the template, validates it the same way the
/// prompt-contract gate does (no `strftime_now`, passes
/// `TemplateRenderCheck.renderOK`), and derives a NEW manifest version from
/// the old manifest's per-file digests plus the new file — no weight bytes
/// are read, so it runs on a laptop against a few small downloaded artifacts.
struct ExtractTemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract-template",
        abstract: "Extract chat_template.jinja from tokenizer_config.json and build a republish manifest for a new version."
    )

    @Option(name: .long, help: "Path to the OLD manifest.json (already downloaded from the old r2_prefix).")
    var manifest: String

    @Option(name: .long, help: "Directory containing the small artifact files downloaded from the old prefix (config.json, tokenizer.json, tokenizer_config.json, ...).")
    var artifactsDir: String

    @Option(name: .long, help: "New version string, e.g. 2026-07-23-r2.")
    var newVersion: String

    @Option(name: .long, help: "Output path for the NEW manifest.json.")
    var output: String

    @Option(name: .long, help: "Output path for the extracted chat_template.jinja.")
    var templateOutput: String

    mutating func validate() throws {
        do {
            try ManifestBuilder.validateVersion(newVersion)
        } catch let ManifestBuilder.Error.invalidVersion(_, reason) {
            throw ValidationError("--new-version: \(reason)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: artifactsDir, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("--artifacts-dir: not a directory: \(artifactsDir)")
        }
    }

    mutating func run() async throws {
        // 1) Decode the old manifest and reject unprocessable ones (wrong
        // schema, already has a standalone template, bad digests).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let oldManifest = try decoder.decode(
            ModelManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        try TemplateExtraction.validateOldManifest(oldManifest)
        guard oldManifest.version != newVersion else {
            throw ValidationError(
                "--new-version equals the old manifest version (\(newVersion)) — republishing onto the same r2_prefix would mutate the old version")
        }

        // 2) Extract the template from tokenizer_config.json (string or
        // [{name, template}] list form).
        let artifactsURL = URL(fileURLWithPath: artifactsDir)
        let tokenizerConfigURL = artifactsURL.appendingPathComponent("tokenizer_config.json")
        guard FileManager.default.fileExists(atPath: tokenizerConfigURL.path) else {
            throw ValidationError("tokenizer_config.json not found in --artifacts-dir: \(tokenizerConfigURL.path)")
        }
        let template = try TemplateExtraction.extractTemplate(
            fromTokenizerConfig: Data(contentsOf: tokenizerConfigURL))

        // 3) Same gates as PromptContractIdentity.compute(modelDirectory:):
        // no dynamic-date templates, and the artifacts dir (WITH the new
        // standalone file) must pass the render self-check.
        try TemplateExtraction.validateDeterministic(template: template)

        let templateData = Data(template.utf8)
        let templateOutputURL = URL(fileURLWithPath: templateOutput)
        try writeCreatingParentDirectory(templateData, to: templateOutputURL)
        try writeCreatingParentDirectory(
            templateData,
            to: artifactsURL.appendingPathComponent(TemplateExtraction.templateFilename))

        switch TemplateRenderCheck.renderOK(at: artifactsURL) {
        case true?:
            break
        case false?:
            throw ValidationError(
                "template failed the render self-check (TemplateRenderCheck) — a template that crashes on canonical request shapes must not ship")
        case nil:
            throw ValidationError(
                "render self-check found no usable template in the artifacts dir — the extracted template is empty or whitespace-only")
        }

        // 4) New manifest = old per-file digests + the new template file;
        // aggregate recomputed digests-only, r2_prefix derived canonically.
        let role = ModelScanner.roleFor(filename: TemplateExtraction.templateFilename)
        let templateSHA = SHA256.hash(data: templateData)
            .map { String(format: "%02x", $0) }.joined()
        let templateFile = ManifestFile(
            path: TemplateExtraction.templateFilename,
            sizeBytes: Int64(templateData.count),
            sha256: templateSHA,
            role: role
        )
        let newManifest = try TemplateExtraction.buildRepublishManifest(
            oldManifest: oldManifest,
            newVersion: newVersion,
            templateFile: templateFile
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try writeCreatingParentDirectory(
            try encoder.encode(newManifest), to: URL(fileURLWithPath: output))

        if !TemplateExtraction.oldPrefixMatchesDerivation(oldManifest) {
            FileHandle.standardError.write(Data("""
                warning: old manifest r2_prefix (\(oldManifest.r2Prefix)) does not match today's \
                derivation for \(oldManifest.modelID)/\(oldManifest.version) — server-side copies \
                must use the OLD prefix as recorded, not a re-derived one\n
                """.utf8))
        }

        print("""
            Republish manifest built.
              model_id:   \(newManifest.modelID)
              version:    \(oldManifest.version)  ->  \(newManifest.version)
              r2_prefix:  \(oldManifest.r2Prefix)  ->  \(newManifest.r2Prefix)
              added file: \(TemplateExtraction.templateFilename) (role \(role), \(templateFile.sizeBytes) bytes)
                sha256:   \(templateSHA)
              aggregate:  \(oldManifest.aggregateSHA256)
                      ->  \(newManifest.aggregateSHA256)
              files:      \(oldManifest.fileCount) -> \(newManifest.fileCount), \
            total \(oldManifest.totalSizeBytes) -> \(newManifest.totalSizeBytes) bytes
              template:   \(templateOutputURL.path)
              manifest:   \(URL(fileURLWithPath: output).path)
            """)
    }

    private func writeCreatingParentDirectory(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
