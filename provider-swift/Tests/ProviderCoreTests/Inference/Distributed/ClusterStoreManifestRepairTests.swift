import Foundation
import Darwin
import Testing
import DarkbloomClusterRuntime
@testable import ProviderCore

/// A cluster-store folder copied over the cable has no product-store receipt on this Mac. After the pin change to the
/// CDN's `manifest.json`, `ClusterProductModelStore.repairStoreManifests` replaces its manifest from the published
/// bytes. `LocalCDNFileServer` plays the model CDN; the coordinator address is a closed loopback port. The worker's
/// answer is the worker's own describe code (`ClusterResidentModelCatalog.describe`), run in this process on the
/// folder's `config.json`. The old manifests in `Fixtures/ClusterManifestRepair/` are the production coordinator's
/// copies that the runtime pinned before 2026-10-28.
@Suite("Cluster store manifest repair for copied folders")
struct ClusterStoreManifestRepairTests {
    private static let binary = String(repeating: "1", count: 64)
    private static let closed = "http://127.0.0.1:9"

    private static var repository: URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.lastPathComponent != "provider-swift", root.path != "/" { root.deleteLastPathComponent() }
        return root.deletingLastPathComponent()
    }
    private static func worker(_ name: String) throws -> Data {
        try Data(contentsOf: repository.appendingPathComponent("libs/darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/\(name)"))
    }
    private static func coordinatorCopy(_ name: String) throws -> Data {
        try Data(contentsOf: repository.appendingPathComponent(
            "provider-swift/Tests/ProviderCoreTests/Fixtures/ClusterManifestRepair/\(name).coordinator-manifest.json"))
    }

    /// The GPT-OSS CDN manifest with one file renamed: the same aggregate, another file list.
    private static func renamedGPTOSSManifest() throws -> Data {
        Data(String(decoding: try worker("registered-gpt-oss-20b.manifest.json"), as: UTF8.self)
            .replacingOccurrences(of: "\"path\" : \"generation_config.json\"", with: "\"path\" : \"generation_config_2.json\"").utf8)
    }
    private static let gptOSSPath = "/v2/gpt-oss-20b--ca1fe4e9c149/2026-05-25-r1/manifest.json"

    /// The worker's answer for `manifest` beside the folder's own configuration.
    private static func describes(_ manifest: Data, _ folder: URL) -> Bool {
        guard let configuration = try? Data(contentsOf: folder.appendingPathComponent("config.json")) else { return false }
        return (try? ClusterResidentModelCatalog.describe(configuration: configuration, manifest: manifest,
                                                          runtimeBinarySHA256: binary)) != nil
    }

    /// A store with one copied folder (configuration, manifest and a stand-in weight file) and a provider
    /// configuration whose coordinator does not answer.
    private struct Store {
        let root: URL, folder: URL, providerConfiguration: URL, weight: URL
        init(folder name: String, configuration: Data, manifest: Data) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-repair-\(UUID().uuidString)", isDirectory: true)
            folder = root.appendingPathComponent("store/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try configuration.write(to: folder.appendingPathComponent("config.json"))
            try manifest.write(to: folder.appendingPathComponent("manifest.json"))
            weight = folder.appendingPathComponent("model-00001-of-00003.safetensors")
            try Data("weights stand-in".utf8).write(to: weight)
            providerConfiguration = root.appendingPathComponent("provider.toml")
            try Data("[coordinator]\nurl = \"ws://127.0.0.1:9/ws/provider\"\n".utf8).write(to: providerConfiguration)
        }
        var store: URL { folder.deletingLastPathComponent() }
        var manifest: Data { (try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))) ?? Data() }
        var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        func repair(cdn: String, servable: Set<String>, now: Date = Date()) {
            ClusterProductModelStore.repairStoreManifests(store: store, servable: servable,
                providerConfiguration: providerConfiguration, environment: ["DARKBLOOM_R2_CDN_URL": cdn], now: now,
                accepts: ClusterStoreManifestRepairTests.describes)
        }
        func weightState() -> (bytes: Data, inode: UInt64, modified: timespec) {
            var information = stat()
            _ = lstat(weight.path, &information)
            return ((try? Data(contentsOf: weight)) ?? Data(), UInt64(information.st_ino), information.st_mtimespec)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func copiedFolderWithTheCoordinatorCopyIsRepairedAndAccepted() async throws {
        let old = try Self.coordinatorCopy("gpt-oss-20b"), published = try Self.worker("registered-gpt-oss-20b.manifest.json")
        let store = try Store(folder: "gpt-oss-20b-2026-05-25-r1",
            configuration: try Self.worker("registered-gpt-oss-20b.configuration.json"), manifest: old)
        defer { store.remove() }
        let server = LocalCDNFileServer()
        let cdn = try await server.start()
        defer { Task { await server.shutdown() } }
        let path = Self.gptOSSPath
        server.setFiles([path: published])
        #expect(!Self.describes(old, store.folder))
        let before = store.weightState()

        let aggregate = try ClusterCatalogArtifact.parse(manifest: old).aggregateSHA256
        store.repair(cdn: cdn.absoluteString, servable: [aggregate])

        #expect(store.manifest == published)
        #expect(Self.describes(store.manifest, store.folder))
        #expect(server.requestedPaths() == [path])
        let after = store.weightState()
        #expect(after.bytes == before.bytes && after.inode == before.inode)
        #expect(after.modified.tv_sec == before.modified.tv_sec && after.modified.tv_nsec == before.modified.tv_nsec)
        #expect(store.names == ["config.json", "manifest.json", "model-00001-of-00003.safetensors"])
    }

    /// A published manifest that names other files is not this folder's artifact: the folder is left as it is.
    @Test func fetchedManifestWithAnotherFileListIsRefused() async throws {
        let old = try Self.coordinatorCopy("gpt-oss-20b")
        let renamed = try Self.renamedGPTOSSManifest()
        let parsed = try ClusterCatalogArtifact.parse(manifest: renamed), held = try ClusterCatalogArtifact.parse(manifest: old)
        #expect(parsed.aggregateSHA256 == held.aggregateSHA256 && !parsed.sameArtifact(held))
        let store = try Store(folder: "gpt-oss-20b-2026-05-25-r1",
            configuration: try Self.worker("registered-gpt-oss-20b.configuration.json"), manifest: old)
        defer { store.remove() }
        let server = LocalCDNFileServer()
        let cdn = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setFiles([Self.gptOSSPath: renamed])

        store.repair(cdn: cdn.absoluteString, servable: [parsed.aggregateSHA256])

        #expect(store.manifest == old)
        #expect(!Self.describes(store.manifest, store.folder))
    }

    /// gemma-4-26b and gemma-4-26b-8bit have the same files, and the worker takes either manifest beside the same
    /// configuration. A published manifest of the other entry does not replace this folder's.
    @Test func fetchedManifestOfAnotherEntryWithTheSameFilesIsRefused() async throws {
        let old = try Self.coordinatorCopy("gemma-4-26b"), other = try Self.worker("registered-gemma4-26b-8bit.manifest.json")
        let store = try Store(folder: "gemma-4-26b-2026-05-25-r1",
            configuration: try Self.worker("registered-gemma4-26b.configuration.json"), manifest: old)
        defer { store.remove() }
        #expect(Self.describes(other, store.folder))
        let server = LocalCDNFileServer()
        let cdn = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setFiles(["/v2/gemma-4-26b--9e201d98f8d4/2026-05-25-r1/manifest.json": other])

        let aggregate = try ClusterCatalogArtifact.parse(manifest: old).aggregateSHA256
        store.repair(cdn: cdn.absoluteString, servable: [aggregate])

        #expect(store.manifest == old)
    }

    /// The CDN has no file the first time (404) and the coordinator does not answer: the folder is asked again after
    /// `ClusterOnboardingUpdate.checkEverySeconds`, not before, and is then repaired.
    @Test func failedFetchIsRetriedAfterTheIntervalAndThenRepairs() async throws {
        let old = try Self.coordinatorCopy("gpt-oss-20b"), published = try Self.worker("registered-gpt-oss-20b.manifest.json")
        let store = try Store(folder: "gpt-oss-20b-2026-05-25-r1",
            configuration: try Self.worker("registered-gpt-oss-20b.configuration.json"), manifest: old)
        defer { store.remove() }
        let server = LocalCDNFileServer()
        let cdn = try await server.start()
        defer { Task { await server.shutdown() } }
        let aggregate = try ClusterCatalogArtifact.parse(manifest: old).aggregateSHA256
        let start = Date(), interval = ClusterOnboardingUpdate.checkEverySeconds

        store.repair(cdn: cdn.absoluteString, servable: [aggregate], now: start)
        #expect(store.manifest == old)
        #expect(server.requestedPaths() == [Self.gptOSSPath])

        server.setFiles([Self.gptOSSPath: published])
        store.repair(cdn: cdn.absoluteString, servable: [aggregate], now: start.addingTimeInterval(interval - 1))
        #expect(store.manifest == old)
        #expect(server.requestedPaths() == [Self.gptOSSPath])

        store.repair(cdn: cdn.absoluteString, servable: [aggregate], now: start.addingTimeInterval(interval))
        #expect(store.manifest == published)
        #expect(Self.describes(store.manifest, store.folder))
        #expect(server.requestedPaths() == [Self.gptOSSPath, Self.gptOSSPath])
    }

    /// A published manifest of other content is a definite answer: the folder is not asked again, even after the
    /// interval and with the right bytes published.
    @Test func contentMismatchIsNotRetried() async throws {
        let old = try Self.coordinatorCopy("gpt-oss-20b")
        let store = try Store(folder: "gpt-oss-20b-2026-05-25-r1",
            configuration: try Self.worker("registered-gpt-oss-20b.configuration.json"), manifest: old)
        defer { store.remove() }
        let server = LocalCDNFileServer()
        let cdn = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setFiles([Self.gptOSSPath: try Self.renamedGPTOSSManifest()])
        let aggregate = try ClusterCatalogArtifact.parse(manifest: old).aggregateSHA256
        let start = Date()

        store.repair(cdn: cdn.absoluteString, servable: [aggregate], now: start)
        #expect(store.manifest == old)

        server.setFiles([Self.gptOSSPath: try Self.worker("registered-gpt-oss-20b.manifest.json")])
        store.repair(cdn: cdn.absoluteString, servable: [aggregate],
                     now: start.addingTimeInterval(ClusterOnboardingUpdate.checkEverySeconds))
        #expect(store.manifest == old)
        #expect(server.requestedPaths() == [Self.gptOSSPath])
    }

    /// Neither the CDN nor the coordinator answers: the folder is unchanged and the worker refuses it as before.
    @Test func unreachableCatalogLeavesTheFolderUnchanged() throws {
        let old = try Self.coordinatorCopy("gpt-oss-20b")
        let store = try Store(folder: "gpt-oss-20b-2026-05-25-r1",
            configuration: try Self.worker("registered-gpt-oss-20b.configuration.json"), manifest: old)
        defer { store.remove() }
        let before = store.weightState()

        let aggregate = try ClusterCatalogArtifact.parse(manifest: old).aggregateSHA256
        store.repair(cdn: Self.closed, servable: [aggregate])

        #expect(store.manifest == old)
        #expect(!Self.describes(store.manifest, store.folder))
        #expect(store.weightState().bytes == before.bytes && store.weightState().inode == before.inode)
        #expect(store.names == ["config.json", "manifest.json", "model-00001-of-00003.safetensors"])
    }
}
