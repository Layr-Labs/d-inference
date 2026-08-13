import Foundation
import MLX
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

private actor StaleFunnelCatalog: SpecDecCatalogLooking {
    private let stale: CatalogModel
    private let fresh: CatalogModel
    private(set) var cachedCalls = 0
    private(set) var freshCalls = 0

    init(stale: CatalogModel, fresh: CatalogModel) {
        self.stale = stale
        self.fresh = fresh
    }

    func cachedModel(id: String) -> CatalogModel? {
        cachedCalls += 1
        return stale
    }

    func model(id: String) async throws -> CatalogModel? { stale }

    func freshModel(id: String) async throws -> CatalogModel? {
        freshCalls += 1
        return fresh
    }
}

private actor SlowFunnelCatalog: SpecDecCatalogLooking {
    func cachedModel(id: String) -> CatalogModel? { nil }
    func model(id: String) async throws -> CatalogModel? {
        try await taskSleep(.seconds(5))
        return nil
    }
}

private actor FunnelSleepProbe {
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) {
        durations.append(duration)
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

private func makeInlineQwenArtifact(includeMTP: Bool = true) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("specdec-inline-qwen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(
        """
        {
          "model_type": "qwen3_5_moe",
          "mtplx_mtp": {"included": true, "prefix": "mtp.", "block_size": 3},
          "mtplx_mtp_quantization": {}
        }
        """.utf8
    ).write(to: root.appendingPathComponent("config.json"))
    let shard = "model-00001-of-00001.safetensors"
    let key = includeMTP ? "mtp.norm.weight" : "language_model.model.norm.weight"
    try MLX.save(
        arrays: [key: MLXArray([Float(1), Float(2), Float(3), Float(4)])],
        url: root.appendingPathComponent(shard))
    let index = try JSONSerialization.data(withJSONObject: [
        "weight_map": [key: shard]
    ])
    try index.write(to: root.appendingPathComponent("model.safetensors.index.json"))
    return root
}

/// HF-cache-style copy of an inline Qwen artifact: the snapshot directory
/// holds only RELATIVE symlinks into a sibling `blobs/` directory — the
/// layout `hf download` materializes and the layout production checkpoints
/// actually load from. Returns (cacheRoot, snapshotDirectory).
private func makeSymlinkedSnapshot(of real: URL) throws -> (root: URL, snapshot: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("specdec-hf-cache-\(UUID().uuidString)", isDirectory: true)
    let blobs = root.appendingPathComponent("blobs", isDirectory: true)
    let snapshot = root.appendingPathComponent("snapshots", isDirectory: true)
        .appendingPathComponent("0123abcd", isDirectory: true)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    for name in try FileManager.default.contentsOfDirectory(atPath: real.path) {
        try FileManager.default.copyItem(
            at: real.appendingPathComponent(name),
            to: blobs.appendingPathComponent("blob-\(name)"))
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent(name).path,
            withDestinationPath: "../../blobs/blob-\(name)")
    }
    return (root, snapshot)
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

    @Test("Qwen combined checkpoint resolves its indexed MTP payload inline")
    func qwenInlineArtifactResolvesWithoutCatalog() async throws {
        let directory = try makeInlineQwenArtifact()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = FunnelCatalog(nil)
        let prepared = await funnel(
            catalog: catalog, root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
                modelType: "qwen3_5_moe",
                enabled: true,
                localPath: nil,
                modelDirectory: directory,
                allowDownload: true,
                environment: [:]))

        let artifact = try #require(prepared.artifact)
        #expect(artifact.source == .inline)
        #expect(artifact.artifactBytes == 16)
        #expect(artifact.inlineIndexSHA256 != nil)
        #expect(prepared.status == .candidate(artifact))
        #expect(await catalog.calls == 0)
    }

    @Test("Qwen checkpoint without indexed MTP fails open before catalog")
    func qwenInvalidInlineArtifactFallsBack() async throws {
        let directory = try makeInlineQwenArtifact(includeMTP: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = FunnelCatalog(funnelModel())
        let prepared = await funnel(
            catalog: catalog, root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
                modelType: "qwen3_5_moe",
                enabled: true,
                localPath: nil,
                modelDirectory: directory,
                allowDownload: true,
                environment: [:]))

        #expect(prepared.artifact == nil)
        #expect(prepared.status.reason == .inlineArtifactInvalid)
        #expect(await catalog.calls == 0)
    }

    @Test("HF-cache symlinked snapshot passes inspection and admits inline MTP")
    func qwenSymlinkedSnapshotActivates() async throws {
        let real = try makeInlineQwenArtifact()
        defer { try? FileManager.default.removeItem(at: real) }
        let (cacheRoot, snapshot) = try makeSymlinkedSnapshot(of: real)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Regular-file baseline and symlinked snapshot must produce the SAME
        // artifact facts — symlinks change the layout, not the payload.
        let baseline = try SpecDecStore.inspectInlineArtifact(directory: real).get()
        let inspected = try SpecDecStore.inspectInlineArtifact(directory: snapshot).get()
        #expect(inspected.source == .inline)
        #expect(inspected.artifactBytes == baseline.artifactBytes)
        #expect(inspected.residentBytes == baseline.residentBytes)
        #expect(inspected.revision == baseline.revision)
        #expect(inspected.localConfigSHA256 == baseline.localConfigSHA256)
        #expect(inspected.inlineIndexSHA256 == baseline.inlineIndexSHA256)

        // The funnel admits the snapshot as a candidate — the admission gate
        // the slot factory consumes…
        let catalog = FunnelCatalog(nil)
        let prepared = await funnel(
            catalog: catalog, root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
                modelType: "qwen3_5_moe",
                enabled: true,
                localPath: nil,
                modelDirectory: snapshot,
                allowDownload: true,
                environment: [:]))
        let artifact = try #require(prepared.artifact)
        #expect(prepared.status == .candidate(artifact))
        #expect(await catalog.calls == 0)

        // …and the pre-load revalidation gate (`EngineV2SlotFactory+MTP` runs
        // `revalidateForLoad` immediately before assistant construction) also
        // resolves, so nothing between admission and drafter build rejects
        // the symlinked layout.
        let revalidation = SpecDecStore.revalidateForLoad(artifact)
        #expect(revalidation.artifact == artifact,
            "revalidation must resolve the admitted artifact; got reason=\(String(describing: revalidation.reason)) detail=\(String(describing: revalidation.detail))")
    }

    @Test("broken symlinked shard is rejected with the concrete reason and path")
    func qwenBrokenSymlinkRejectedLoudly() async throws {
        let real = try makeInlineQwenArtifact()
        defer { try? FileManager.default.removeItem(at: real) }
        let (cacheRoot, snapshot) = try makeSymlinkedSnapshot(of: real)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Break the shard link: point it at a blob that does not exist.
        let shard = "model-00001-of-00001.safetensors"
        let shardLink = snapshot.appendingPathComponent(shard)
        try FileManager.default.removeItem(at: shardLink)
        try FileManager.default.createSymbolicLink(
            atPath: shardLink.path,
            withDestinationPath: "../../blobs/deleted-blob")

        // The inspection result names the failing file, not just a status.
        switch SpecDecStore.inspectInlineArtifact(directory: snapshot) {
        case .success:
            Issue.record("broken symlinked shard must not pass inspection")
        case .failure(let rejection):
            #expect(rejection.description.contains("broken symlink"))
            #expect(rejection.description.contains(shard))
        }

        // The funnel maps it to the existing fail-open status.
        let catalog = FunnelCatalog(nil)
        let prepared = await funnel(
            catalog: catalog, root: FileManager.default.temporaryDirectory
        ).prepare(
            .init(
                modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
                modelType: "qwen3_5_moe",
                enabled: true,
                localPath: nil,
                modelDirectory: snapshot,
                allowDownload: true,
                environment: [:]))
        #expect(prepared.artifact == nil)
        #expect(prepared.status.reason == .inlineArtifactInvalid)
    }

    @Test("regular-file inline inspection facts and revalidation are unchanged")
    func qwenRegularFileInlineBehaviorUnchanged() throws {
        let real = try makeInlineQwenArtifact()
        defer { try? FileManager.default.removeItem(at: real) }
        let artifact = try SpecDecStore.inspectInlineArtifact(directory: real).get()
        #expect(artifact.source == .inline)
        #expect(artifact.artifactBytes == 16)
        #expect(artifact.inlineIndexSHA256 != nil)
        #expect(SpecDecStore.revalidateForLoad(artifact).artifact == artifact)

        // A checkpoint that does not carry inline MTP still reports the
        // concrete reason instead of a bare nil.
        let plain = try makeInlineQwenArtifact(includeMTP: false)
        defer { try? FileManager.default.removeItem(at: plain) }
        switch SpecDecStore.inspectInlineArtifact(directory: plain) {
        case .success:
            Issue.record("checkpoint without inline MTP tensors must not pass")
        case .failure(let rejection):
            #expect(rejection.description.contains("no tensors with prefix"))
        }
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
        let missingFunnel = funnel(
            catalog: missingCatalog, root: FileManager.default.temporaryDirectory)
        let missing = await missingFunnel.prepare(
            .init(
                modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
                localPath: nil, allowDownload: true, environment: [:]))
        #expect(missing.status.reason == .metadataMissing)
        await missingFunnel.shutdown()

        let malformedCatalog = FunnelCatalog(funnelModel(metadata: [
            "spec_dec": .object([("r2_prefix", .string("../escape"))])
        ]))
        let malformedFunnel = funnel(
            catalog: malformedCatalog, root: FileManager.default.temporaryDirectory)
        let malformed = await malformedFunnel.prepare(
            .init(
                modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
                localPath: nil, allowDownload: true, environment: [:]))
        #expect(malformed.status.reason == .metadataMalformed)
        await malformedFunnel.shutdown()
    }

    @Test("stale cached entry without spec_dec triggers one cooldown-gated refresh")
    func staleCatalogEntryRefreshes() async throws {
        let catalog = StaleFunnelCatalog(
            stale: funnelModel(),
            fresh: funnelModel(metadata: [
                "spec_dec": .object([("r2_prefix", .string("v2-specdec/gemma/v1"))])
            ]))
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("specdec-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let artifactFunnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: store, cdnBaseURL: "http://127.0.0.1:1"),
            catalog: catalog)
        let request = SpecDecArtifactFunnel.Request(
            modelId: "gemma-4-target", modelType: "gemma4", enabled: true,
            localPath: nil, allowDownload: true, environment: [:])

        // The cached entry is stale (no spec_dec): the prepare itself stays
        // fail-open, but a background catalog refresh must be scheduled so a
        // coordinator that added spec_dec to an existing id can roll out
        // without a provider restart.
        let first = await artifactFunnel.prepare(request)
        #expect(first.status.reason == .metadataMissing)
        // An immediate second prepare must not schedule a second refresh
        // (in-flight dedupe now, cooldown stamp afterwards).
        _ = await artifactFunnel.prepare(request)
        for _ in 0 ..< 200 {
            if await catalog.freshCalls > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await catalog.freshCalls == 1)

        // Wait for the refresh task to finish (its prefetch against the dead
        // CDN fails fast), then verify the cooldown blocks a re-refresh.
        for _ in 0 ..< 200 {
            if await artifactFunnel.prefetchInFlightForTesting == 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = await artifactFunnel.prepare(request)
        await artifactFunnel.shutdown()
        #expect(await catalog.freshCalls == 1)
        // A local-only prepare never schedules refreshes at all.
        #expect(await catalog.cachedCalls > 0)
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

    @Test("catalog prewarm fails open when the short deadline wins")
    func prewarmDeadline() async {
        let sleepProbe = FunnelSleepProbe()
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(
                storeRoot: FileManager.default.temporaryDirectory,
                cdnBaseURL: "http://127.0.0.1:1"),
            catalog: SlowFunnelCatalog())
        let warmed = await funnel.prewarmCatalog(
            modelId: "gemma-4-target",
            timeout: .milliseconds(20),
            sleep: { duration in await sleepProbe.sleep(duration) })
        #expect(!warmed)
        #expect(await sleepProbe.durations == [.milliseconds(20)])
        await funnel.shutdown()
    }
}
