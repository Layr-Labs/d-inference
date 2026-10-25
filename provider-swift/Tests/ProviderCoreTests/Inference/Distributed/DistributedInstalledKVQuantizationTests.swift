import DarkbloomClusterRemote
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The pair's live KV precision comes from the product's own settings, resolved
/// exactly as the single-Mac engine resolves them, and reaches the native rank
/// only as a resolved name (nothing for native, the rank's default).
@Suite("Installed pair live KV precision", .serialized)
struct DistributedInstalledKVQuantizationTests {
    typealias Precision = DistributedInstalledKVQuantization
    static let model = "EigenLabs/Qwen3.8-27B-4bit-mtp"

    @Test func ownerResolvesLikeMainWithMainsDefault() {
        let key = Precision.switchName
        #expect(key == EngineV2KVQuantizationPolicy.environmentKey)
        let defaults = Precision.resolver(backend: BackendSettings())
        #expect(defaults(Self.model, [:]) == nil)
        let global = Precision.resolver(backend: BackendSettings(engineV2KVQuantization: "balanced"))
        #expect(global(Self.model, [:]) == "balanced")
        // The switch, then the per-model setting, then the global setting.
        let settings = BackendSettings(engineV2KVQuantization: "balanced",
            engineV2KVQuantizationByModel: [Self.model: "k8v8"])
        let resolver = Precision.resolver(backend: settings)
        #expect(resolver(Self.model, [:]) == "k8v8")
        #expect(resolver("another-model", [:]) == "balanced")
        #expect(resolver(Self.model, [key: "int4"]) == "balanced")
        #expect(resolver(Self.model, [key: "native"]) == nil)
        // Main's checkpoint precision is not live storage.
        #expect(defaults(Self.model, [EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: "k8v8"]) == nil)
        // A setting main refuses reaches the rank as a bounded name; the rank refuses it by name.
        #expect(Precision.resolver(backend: BackendSettings(engineV2KVQuantization: "k4v44"))(Self.model, [:]) == "k4v44")
        #expect(Precision.resolver(backend: BackendSettings(engineV2KVQuantization: "k4 v4\u{0}"))(Self.model, [:])
            == "invalid")
        #expect(resolver(Self.model, [key: "k8-v4"]) == "invalid")
    }

    @Test func theRankGetsTheResolvedNameOnlyWhenItIsNotNative() {
        defer { Precision.install(nil) }
        Precision.install(nil)
        #expect(Precision.environment(publicModelID: Self.model, ownerEnvironment: [Precision.switchName: "k8v4"]).isEmpty)
        Precision.install(Precision.resolver(backend: BackendSettings()))
        #expect(Precision.environment(publicModelID: Self.model, ownerEnvironment: [:]).isEmpty)
        #expect(Precision.environment(publicModelID: Self.model, ownerEnvironment: [Precision.switchName: "on"])
            == [Precision.switchName: "balanced"])
    }

    @Test func savedSettingsAreReadFromTheProviderConfiguration() throws {
        // The private-mode reader refuses symlinked path components (/var is one),
        // so the directory lives inside the checkout, as the cache settings test's does.
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".kv-precision-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("provider.toml")
        #expect(try Precision.savedBackendSettings(providerConfiguration: file).engineV2KVQuantization == "native")
        try Data("[backend]\nengine_v2_kv_quantization = \"k8v4\"\n".utf8).write(to: file)
        chmod(file.path, 0o600)
        let saved = try Precision.savedBackendSettings(providerConfiguration: file)
        #expect(saved.engineV2KVQuantization == "k8v4")
        #expect(Precision.resolver(backend: saved)(Self.model, [:]) == "k8v4")
    }

    @Test func onlyAShortNameIsForwardedToTheOwnerItStarts() throws {
        let key = Precision.switchName
        #expect(Precision.forwardedSwitch([:]) == nil)
        #expect(Precision.forwardedSwitch([key: " K8V8 "]) == "k8v8")
        // Main reads an empty switch as its default and refuses a malformed one.
        #expect(Precision.forwardedSwitch([key: " "]) == "native")
        for raw in ["k8 v8", "k8v8;rm", String(repeating: "a", count: 17), "ä"] {
            #expect(Precision.forwardedSwitch([key: raw]) == "invalid", "\(raw)")
        }
        let owner = URL(fileURLWithPath: "/usr/local/bin/darkbloom")
        _ = try ClusterLocalOwnerConfiguration(installedDarkbloom: owner, kvQuantization: "balanced")
        #expect(throws: (any Error).self) {
            _ = try ClusterLocalOwnerConfiguration(installedDarkbloom: owner, kvQuantization: "Balanced")
        }
    }
}
