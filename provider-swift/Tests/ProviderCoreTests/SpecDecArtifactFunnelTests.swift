import Foundation
import Testing
@testable import ProviderCore

private actor FunnelCatalog: SpecDecCatalogLooking {
    private let value: CatalogModel?
    private(set) var calls = 0

    init(_ value: CatalogModel?) { self.value = value }

    func cachedModel(id: String) -> CatalogModel? { value }

    func model(id: String) async throws -> CatalogModel? {
        calls += 1
        return value
    }
}

private actor GatedFunnelCatalog: SpecDecCatalogLooking {
    private let value: CatalogModel
    private var continuation: CheckedContinuation<CatalogModel?, any Error>?
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var cancellations = 0

    init(_ value: CatalogModel) { self.value = value }

    func cachedModel(id: String) -> CatalogModel? { nil }

    func model(id: String) async throws -> CatalogModel? {
        calls += 1
        active += 1
        defer { active -= 1 }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }

    private func recordCancellation() { cancellations += 1 }
}

private actor SlowFunnelCatalog: SpecDecCatalogLooking {
    func cachedModel(id: String) -> CatalogModel? { nil }
    func model(id: String) async throws -> CatalogModel? {
        try await taskSleep(.seconds(5))
        return nil
    }
}

private func funnelModel(id: String = "gemma-4-target", metadata: [String: JSONValue]? = nil) -> CatalogModel {
    CatalogModel(
        id: id, s3Name: "unused", displayName: id, sizeGb: 1,
        metadata: metadata)
}

private let localAssistantConfig = Data(#"{"model_type":"gemma4_assistant"}"#.utf8)

private func makeLocalAssistant() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("specdec-local-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try localAssistantConfig.write(to: root.appendingPathComponent("config.json"))
    try Data(repeating: 0x5a, count: 4096)
        .write(to: root.appendingPathComponent("model.safetensors"))
    return root
}

@Suite("SpecDec production artifact funnel")
struct SpecDecArtifactFunnelTests {
    private func funnel(catalog: FunnelCatalog, root: URL) -> SpecDecArtifactFunnel {
        SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: root, cdnBaseURL: "http://127.0.0.1:1"),
            catalog: catalog)
    }

    @Test("local override takes precedence and never reads catalog")
    func localPrecedence() async throws {
        let local = try makeLocalAssistant()
        defer { try? FileManager.default.removeItem(at: local) }
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("specdec-store-\(UUID().uuidString)")
        let catalog = FunnelCatalog(nil)
        let prepared = await funnel(catalog: catalog, root: store).prepare(
            .init(
                modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
                localPath: local.path, allowDownload: true, environment: [:]))
        let artifact = try #require(prepared.artifact)
        #expect(artifact.source == .local)
        #expect(artifact.artifactBytes == UInt64(4096 + localAssistantConfig.count))
        #expect(artifact.residentBytes == SpecDecLimits.residentEstimate(
            artifactBytes: artifact.artifactBytes))
        #expect(await catalog.calls == 0)
    }

    @Test("invalid local override does not silently activate catalog assistant")
    func invalidLocalDoesNotFallThrough() async {
        let catalog = FunnelCatalog(funnelModel(metadata: [
            "spec_dec": .object([("r2_prefix", .string("v2-specdec/other/v1"))])
        ]))
        let prepared = await funnel(
            catalog: catalog,
            root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
                localPath: "/definitely/missing", allowDownload: true, environment: [:]))
        #expect(prepared.artifact == nil)
        #expect(prepared.status.reason == .localArtifactInvalid)
        #expect(await catalog.calls == 0)
    }

    @Test("non-Gemma target never resolves or loads an assistant")
    func nonGemmaExcludedBeforeCatalog() async {
        let catalog = FunnelCatalog(funnelModel())
        let prepared = await funnel(
            catalog: catalog,
            root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "gpt-oss", modelType: "gpt_oss", enabled: true,
                localPath: nil, allowDownload: true, environment: [:]))
        #expect(prepared.status.reason == .targetUnsupported)
        #expect(await catalog.calls == 0)
    }

    @Test("assistant-like Gemma namespace variants are rejected before catalog")
    func assistantNamespaceVariantsExcluded() async {
        let catalog = FunnelCatalog(funnelModel())
        let artifactFunnel = funnel(
            catalog: catalog, root: FileManager.default.temporaryDirectory)
        for type in ["gemma4_assistant_v2", "gemma4_text_assistant", "gemma4_mtp"] {
            let prepared = await artifactFunnel.prepare(.init(
                modelId: "gemma", modelType: type, enabled: true,
                localPath: nil, allowDownload: true, environment: [:]))
            #expect(prepared.status.reason == .targetUnsupported, "type=\(type)")
        }
        #expect(await catalog.calls == 0)
    }

    @Test("local assistant rejects symlink roots and children")
    func localSymlinksRejected() throws {
        let real = try makeLocalAssistant()
        defer { try? FileManager.default.removeItem(at: real) }
        let rootLink = real.deletingLastPathComponent()
            .appendingPathComponent("specdec-root-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: rootLink) }
        #expect(SpecDecStore.inspectLocalArtifact(path: rootLink.path) == nil)

        let childRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("specdec-child-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: childRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: childRoot) }
        try localAssistantConfig.write(to: childRoot.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            at: childRoot.appendingPathComponent("model.safetensors"),
            withDestinationURL: real.appendingPathComponent("model.safetensors"))
        #expect(SpecDecStore.inspectLocalArtifact(path: childRoot.path) == nil)
    }

    @Test("local assistant config is capped before loader admission")
    func localConfigCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("specdec-config-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x20, count: Int(SpecDecLimits.maximumConfigBytes + 1))
            .write(to: root.appendingPathComponent("config.json"))
        try Data([0x01]).write(to: root.appendingPathComponent("model.safetensors"))
        #expect(SpecDecStore.inspectLocalArtifact(path: root.path) == nil)
    }

    @Test("default off and kill switch are target-only before catalog lookup")
    func disabledStates() async {
        let catalog = FunnelCatalog(funnelModel())
        let artifactFunnel = funnel(
            catalog: catalog,
            root: FileManager.default.temporaryDirectory)
        let off = await artifactFunnel.prepare(
            .init(
                modelId: "gemma", modelType: "gemma4", enabled: false,
                localPath: nil, allowDownload: true, environment: [:]))
        let killed = await artifactFunnel.prepare(
            .init(
                modelId: "gemma", modelType: "gemma4", enabled: true,
                localPath: nil, allowDownload: true,
                environment: ["DARKBLOOM_CBV2_MTP": "off"]))
        #expect(off.status == .disabled(.configDisabled, configured: false))
        #expect(killed.status == .disabled(.killSwitchDisabled, configured: true))
        #expect(await catalog.calls == 0)
    }

    @Test("missing and malformed metadata return stable fail-open reasons")
    func metadataReasons() async {
        let missingCatalog = FunnelCatalog(funnelModel())
        let missing = await funnel(
            catalog: missingCatalog,
            root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
                localPath: nil, allowDownload: true, environment: [:]))
        #expect(missing.status.reason == .metadataMissing)

        let malformedCatalog = FunnelCatalog(funnelModel(metadata: [
            "spec_dec": .object([("r2_prefix", .string("../escape"))])
        ]))
        let malformed = await funnel(
            catalog: malformedCatalog,
            root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
                localPath: nil, allowDownload: true, environment: [:]))
        #expect(malformed.status.reason == .metadataMalformed)
    }

    @Test("local-only policy never constructs or queries a coordinator catalog")
    func localOnlyWithoutPathIsNetworkIndependent() async {
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(
                storeRoot: FileManager.default.temporaryDirectory,
                cdnBaseURL: "http://127.0.0.1:1"),
            catalog: nil)
        let prepared = await funnel.prepare(
            .init(
                modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
                localPath: nil, allowDownload: false, environment: [:]))
        #expect(prepared.artifact == nil)
        #expect(prepared.status.reason == .catalogDisabled)
        await funnel.shutdown()
    }

    @Test("shutdown is terminal across queued and reentrant prefetch scheduling")
    func shutdownRejectsReentrantWorkWithoutTaskLeak() async throws {
        let catalog = GatedFunnelCatalog(funnelModel())
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("specdec-shutdown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(
                storeRoot: store, cdnBaseURL: "http://127.0.0.1:1"),
            catalog: catalog)
        let request = SpecDecArtifactFunnel.Request(
            modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
            localPath: nil, allowDownload: true, environment: [:])

        _ = await funnel.prepare(request)
        for _ in 0..<100 {
            if await catalog.calls > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let shutdown = Task { await funnel.shutdown() }
        for _ in 0..<100 {
            if await catalog.cancellations > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let reentrant = await funnel.prepare(request)
        #expect(reentrant.artifact == nil)
        #expect(reentrant.status.reason == .catalogUnavailable)
        #expect(await catalog.calls == 1)

        await catalog.release()
        await shutdown.value
        let after = await funnel.prepare(request)
        #expect(after.status.reason == .catalogUnavailable)
        #expect(await catalog.calls == 1)
        #expect(await catalog.active == 0)
        #expect(await catalog.cancellations == 1)
    }

    @Test("catalog prewarm has a short fail-open deadline")
    func prewarmDeadline() async {
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(
                storeRoot: FileManager.default.temporaryDirectory,
                cdnBaseURL: "http://127.0.0.1:1"),
            catalog: SlowFunnelCatalog())
        let started = ContinuousClock.now
        let warmed = await funnel.prewarmCatalog(
            modelId: "gemma-4-target", timeout: .milliseconds(20))
        #expect(!warmed)
        #expect(ContinuousClock.now - started < .milliseconds(250))
        await funnel.shutdown()
    }
}
