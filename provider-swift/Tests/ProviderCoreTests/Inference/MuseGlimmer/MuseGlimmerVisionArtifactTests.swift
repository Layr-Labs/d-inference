// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLLM
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// `MuseGlimmerVisionArtifact`: the switch, the identity, the pinned vision
/// stack, then the pinned bytes of `config.json`, `processor_config.json`
/// and the index, each read as a bounded regular file. Discovery advertises
/// images and the load builds the encoder from this one decision.
///
/// Synthetic snapshots carry their own pins; the real pins are checked
/// against the downloaded artifact when `MUSE_GLIMMER_NVFP4_DIR` names it
/// (metadata only, no tensor is read).
@Suite("Muse Glimmer vision artifact")
struct MuseGlimmerVisionArtifactTests {
    typealias Artifact = MuseGlimmerVisionArtifact
    static let on = [MuseGlimmerVisionPolicy.switchEnvironmentKey: "1"]
    static let modelID = MuseGlimmerModelPolicy.localModelID
    static let referenceDirectoryKey = "MUSE_GLIMMER_NVFP4_DIR"

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func configuration(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object: [String: Any] = [
            "model_type": "muse_glimmer", "image_token_id": 200_092, "video_token_id": 200_091,
            "vision_config": [
                "model_type": "muse_glimmer_vision", "patch_size": 14, "merge_size": 2,
                "patch_temporal": 2, "hidden_size": 1_536, "num_hidden_layers": 50,
            ] as [String: Any],
        ]
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A snapshot of the three metadata files and the pins of its own bytes.
    struct Snapshot {
        let directory: URL
        var pins: Artifact.Pins

        init(configuration: Data? = nil) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("muse-glimmer-vision-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files: [(String, Data)] = [
                (Artifact.configurationFile, try configuration ?? MuseGlimmerVisionArtifactTests.configuration()),
                (Artifact.processorConfigurationFile, Data(#"{"max_image_tokens": 4096}"#.utf8)),
                (Artifact.indexFile, Data(#"{"weight_map": {}}"#.utf8)),
            ]
            for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
            pins = Artifact.Pins(
                configuration: sha256(files[0].1), processorConfiguration: sha256(files[1].1),
                index: sha256(files[2].1))
        }

        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

        func decision(
            modelID: String? = MuseGlimmerVisionArtifactTests.modelID,
            environment: [String: String] = MuseGlimmerVisionArtifactTests.on
        ) -> Artifact.Decision {
            Artifact.decision(snapshotDir: directory, modelID: modelID, environment: environment, pins: pins)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("the production pins are the policy's and the SDK installer's")
    func productionPins() {
        let pins = Artifact.Pins()
        #expect(pins.configuration == MuseGlimmerVisionPolicy.pinnedConfigurationSHA256)
        #expect(pins.processorConfiguration == MuseGlimmerVisionPolicy.pinnedProcessorConfigurationSHA256)
        #expect(pins.index == MuseGlimmerCheckpointPin.index)
    }

    @Test("the provider's token ids and ceiling are the SDK's")
    func constantsMatchTheSDK() {
        #expect(MuseGlimmerVisionPolicy.imageTokenID == MuseGlimmerImagePrompt.imageTokenID)
        #expect(MuseGlimmerVisionPolicy.videoTokenID == MuseGlimmerImagePrompt.videoTokenID)
        #expect(MuseGlimmerVisionPolicy.maximumImageTokens == MuseGlimmerImageGeometry.maximumImageTokens)
        #expect(MuseGlimmerVisionPolicy.framingTokens == MuseGlimmerImageGeometry.framingTokens)
        #expect(MuseGlimmerVisionPolicy.maximumPromptTokensPerImage
            == MuseGlimmerImageGeometry.maximumPromptTokensPerImage)
        #expect(MuseGlimmerVisionBudget.patchValues == MuseGlimmerImageGeometry.patchValues)
    }

    @Test("a pinned snapshot serves, and hands over the hashed configuration")
    func pinnedSnapshotServes() throws {
        let snapshot = try Snapshot()
        defer { snapshot.remove() }
        let expected = try Data(contentsOf: snapshot.url(Artifact.configurationFile))
        #expect(snapshot.decision() == .serves(configuration: expected))
        #expect(snapshot.decision(modelID: MuseGlimmerModelPolicy.catalogModelID) == .serves(configuration: expected))
    }

    @Test("the switch is read before any file")
    func switchFirst() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        #expect(Artifact.decision(snapshotDir: missing, modelID: Self.modelID, environment: [:]) == .refused(.switchedOff))
        let snapshot = try Snapshot()
        defer { snapshot.remove() }
        for value in ["0", "true", ""] {
            #expect(snapshot.decision(environment: [MuseGlimmerVisionPolicy.switchEnvironmentKey: value])
                == .refused(.switchedOff))
        }
    }

    @Test("identity and stack refusals come from the hashed configuration")
    func identityAndStack() throws {
        let snapshot = try Snapshot()
        defer { snapshot.remove() }
        #expect(snapshot.decision(modelID: nil) == .refused(.notServingIdentity))
        #expect(snapshot.decision(modelID: "nvidia/Muse-Glimmer-30B-BF16") == .refused(.notServingIdentity))
        let overlay = try Snapshot(configuration: try Self.configuration { $0["language_model_only"] = true })
        defer { overlay.remove() }
        #expect(overlay.decision() == .refused(.configuration))
        let other = try Snapshot(configuration: try Self.configuration { $0.removeValue(forKey: "vision_config") })
        defer { other.remove() }
        #expect(other.decision() == .refused(.configuration))
    }

    @Test("each metadata file must be the pinned bytes")
    func eachFileIsPinned() throws {
        for name in [Artifact.configurationFile, Artifact.processorConfigurationFile, Artifact.indexFile] {
            let snapshot = try Snapshot()
            defer { snapshot.remove() }
            var bytes = try Data(contentsOf: snapshot.url(name))
            bytes.append(0x20)
            try bytes.write(to: snapshot.url(name))
            #expect(snapshot.decision() == .refused(.unpinnedArtifact(file: name)), "\(name)")
        }
        for name in [Artifact.configurationFile, Artifact.processorConfigurationFile, Artifact.indexFile] {
            let snapshot = try Snapshot()
            defer { snapshot.remove() }
            try FileManager.default.removeItem(at: snapshot.url(name))
            #expect(snapshot.decision() == .refused(.unpinnedArtifact(file: name)), "\(name)")
        }
    }

    @Test("a pinned configuration that is no JSON object is refused as unpinned")
    func configurationMustBeAnObject() throws {
        let snapshot = try Snapshot(configuration: Data("[1, 2]".utf8))
        defer { snapshot.remove() }
        #expect(snapshot.decision() == .refused(.unpinnedArtifact(file: Artifact.configurationFile)))
    }

    @Test("a symlinked metadata file is refused, even to the pinned bytes")
    func symlinksAreRefused() throws {
        for name in [Artifact.configurationFile, Artifact.processorConfigurationFile, Artifact.indexFile] {
            let snapshot = try Snapshot()
            defer { snapshot.remove() }
            let target = snapshot.directory.appendingPathComponent("blob-\(name)")
            try FileManager.default.moveItem(at: snapshot.url(name), to: target)
            try FileManager.default.createSymbolicLink(at: snapshot.url(name), withDestinationURL: target)
            #expect(snapshot.decision() == .refused(.unpinnedArtifact(file: name)), "\(name)")
        }
    }

    @Test("a metadata file over its bound is refused before it is hashed")
    func oversizeIsRefused() throws {
        let bounds = [
            (Artifact.configurationFile, Artifact.maximumConfigurationBytes),
            (Artifact.processorConfigurationFile, Artifact.maximumProcessorConfigurationBytes),
            (Artifact.indexFile, Artifact.maximumIndexBytes),
        ]
        for (name, bound) in bounds {
            var snapshot = try Snapshot()
            defer { snapshot.remove() }
            // Valid for its file (JSON padded with spaces), and pinned: only the size refuses it.
            var bytes = try Data(contentsOf: snapshot.url(name))
            bytes.append(Data(repeating: 0x20, count: bound + 1 - bytes.count))
            try bytes.write(to: snapshot.url(name))
            switch name {
            case Artifact.configurationFile: snapshot.pins.configuration = Self.sha256(bytes)
            case Artifact.processorConfigurationFile: snapshot.pins.processorConfiguration = Self.sha256(bytes)
            default: snapshot.pins.index = Self.sha256(bytes)
            }
            #expect(snapshot.decision() == .refused(.unpinnedArtifact(file: name)), "\(name)")
        }
        // The bounds sit well above the pinned files (88,682, 1,084 and 213,580 bytes).
        #expect(Artifact.maximumConfigurationBytes > 88_682 * 4)
        #expect(Artifact.maximumProcessorConfigurationBytes > 1_084 * 4)
        #expect(Artifact.maximumIndexBytes > 213_580 * 4)
    }

    @Test("discovery advertises images only for the exact identity and type")
    func advertisement() throws {
        // The production pins never match a synthetic snapshot, so nothing advertises here.
        let snapshot = try Snapshot()
        defer { snapshot.remove() }
        #expect(!Artifact.advertisesImages(
            snapshotDir: snapshot.directory, modelID: Self.modelID, modelType: "muse_glimmer"))
        #expect(!Artifact.advertisesImages(
            snapshotDir: snapshot.directory, modelID: "other", modelType: "muse_glimmer"))
        #expect(!Artifact.advertisesImages(
            snapshotDir: snapshot.directory, modelID: Self.modelID, modelType: "qwen3_5"))
    }

    @Test(
        "the downloaded artifact is the pinned one (MUSE_GLIMMER_NVFP4_DIR)",
        .enabled(if: ProcessInfo.processInfo.environment["MUSE_GLIMMER_NVFP4_DIR"] != nil))
    func downloadedArtifact() throws {
        let path = try #require(ProcessInfo.processInfo.environment[Self.referenceDirectoryKey])
        let directory = URL(fileURLWithPath: path)
        let configuration = try Data(contentsOf: directory.appendingPathComponent(Artifact.configurationFile))
        #expect(Self.sha256(configuration) == MuseGlimmerVisionPolicy.pinnedConfigurationSHA256)
        #expect(Artifact.decision(snapshotDir: directory, modelID: Self.modelID, environment: Self.on)
            == .serves(configuration: configuration))
        #expect(Artifact.decision(snapshotDir: directory, modelID: Self.modelID, environment: [:])
            == .refused(.switchedOff))
        let object = try #require(JSONSerialization.jsonObject(with: configuration) as? [String: Any])
        #expect(MuseGlimmerVisionPolicy.configurationRefusal(object, modelID: Self.modelID, environment: Self.on) == nil)
    }
}
