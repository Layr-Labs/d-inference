import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Gemma 4's assistant on a tensor-parallel pair, once a build declares it public
/// (`ClusterPublicModels.gemmaTensorAssistant`): the declaration, what it adds to the resource policy a coordinator's
/// approval and every start carry, the worker arguments each member launches with from its own copy of the catalog
/// artifact, and finding that copy. This build declares none yet; each test declares one
/// (`ClusterPublicModels.declarationOverride`), never a product path.
@Suite("Public Gemma tensor assistant", .serialized)
struct ClusterPublicGemmaAssistantTests {
    static let report = "docs/reports/2026-11-06-gemma-tp-assistant.md"
    static let qualifiedAt = "2026-11-06T00:00:00Z"
    static let gemma = "registered_gemma4_26b_qat_4bit"
    static func hash(_ c: Character) -> String { String(repeating: c, count: 64) }

    static func assistant(depth: Int = 3) throws -> ClusterPublicGemmaTensorAssistant {
        try ClusterPublicGemmaTensorAssistant(depth: depth, aggregateSHA256: hash("a"), evidenceDocument: report,
                                              evidenceSHA256: hash("d"), qualifiedAt: qualifiedAt)
    }

    static func declaration(_ assistant: ClusterPublicGemmaTensorAssistant?, families: [ClusterPairServingModeFamily]
                            = [.pipeline, .tensorParallel]) -> [ClusterPublicModel] {
        var model = ClusterPublicModel(runtimeModelID: gemma, catalogModelID: "gemma-4-26b-qat-4bit",
            artifactSHA256: hash("b"), families: families, schedules: [1, 2], ranks: ClusterPublicModels.twoM5Ultras)
        model.gemmaTensorAssistant = assistant
        return [model]
    }

    @Test func aDeclarationNamesItsDepthArtifactReportAndInstant() throws {
        let declared = try Self.assistant()
        #expect(declared.resourcePolicyFields == ["gemma4_tensor_assistant_v1", "depth=3",
            "--gemma-assistant-sha256=" + Self.hash("a"), "evidence=" + Self.hash("d")])
        for depth in [0, 5] { #expect(throws: (any Error).self) { try Self.assistant(depth: depth) } }
        for (aggregate, document, digest, instant) in [("x", Self.report, Self.hash("d"), Self.qualifiedAt),
                                                       (Self.hash("a"), "notes/gemma.md", Self.hash("d"), Self.qualifiedAt),
                                                       (Self.hash("a"), Self.report, "x", Self.qualifiedAt),
                                                       (Self.hash("a"), Self.report, Self.hash("d"), "2026-11-06")] {
            #expect(throws: (any Error).self) {
                try ClusterPublicGemmaTensorAssistant(depth: 3, aggregateSHA256: aggregate, evidenceDocument: document,
                                                      evidenceSHA256: digest, qualifiedAt: instant)
            }
        }
    }

    /// Only the declared Gemma row with tensor parallel among its families has the assistant; nothing in this build
    /// declares one yet.
    @Test func onlyTheDeclaredGemmaRowInTensorParallelHasTheAssistant() throws {
        let declared = try Self.assistant()
        try ClusterPublicModels.$declarationOverride.withValue(Self.declaration(declared)) {
            #expect(ClusterPublicModels.gemmaTensorAssistant(runtimeModelID: Self.gemma, artifactSHA256: Self.hash("b")) == declared)
            #expect(ClusterPublicModels.gemmaTensorAssistant(runtimeModelID: Self.gemma, artifactSHA256: Self.hash("c")) == nil)
        }
        ClusterPublicModels.$declarationOverride.withValue(Self.declaration(declared, families: [.pipeline])) {
            #expect(ClusterPublicModels.gemmaTensorAssistant(runtimeModelID: Self.gemma, artifactSHA256: Self.hash("b")) == nil)
        }
        #expect(ClusterPublicModels.declared.allSatisfy { $0.gemmaTensorAssistant == nil })
    }

    /// Each member launches both its workers with the declared depth and aggregate from its own copy; a member
    /// without the copy refuses rather than start plain beside a peer that speculates.
    @Test func eachMemberLaunchesFromItsOwnCopyOrRefuses() throws {
        let declared = try Self.assistant()
        let arguments = try DistributedInstalledGenerationSelection.gemmaAssistantArguments(declared) {
            $0 == Self.hash("a") ? URL(fileURLWithPath: "/Users/owner/spec-dec/abc", isDirectory: true) : nil
        }
        #expect(arguments == ["--mtp-depth", "3", "--gemma-assistant-dir", "/Users/owner/spec-dec/abc",
                              "--gemma-assistant-sha256", Self.hash("a")])
        #expect(throws: (any Error).self) {
            try DistributedInstalledGenerationSelection.gemmaAssistantArguments(declared) { _ in nil }
        }
    }

    /// The published copy is the store directory whose manifest names the aggregate; staging and other artifacts are
    /// passed over.
    @Test func thePublishedCopyIsFoundByItsManifestAggregate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-dec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func publish(_ name: String, aggregate: String) throws {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = ModelManifest(schemaVersion: 1, modelID: "gemma-assistant", version: "1", r2Prefix: "p/\(name)",
                aggregateSHA256: aggregate, totalSizeBytes: 0, fileCount: 0, files: [], createdAt: Date(timeIntervalSince1970: 0))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        }
        try publish("other", aggregate: Self.hash("c"))
        try publish(".staging-x", aggregate: Self.hash("a"))
        try publish("assistant", aggregate: Self.hash("a"))
        #expect(SpecDecStore.publishedDirectory(aggregateSHA256: Self.hash("a"), root: root)?.lastPathComponent == "assistant")
        #expect(SpecDecStore.publishedDirectory(aggregateSHA256: Self.hash("e"), root: root) == nil)
    }
}
