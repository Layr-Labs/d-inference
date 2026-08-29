import Foundation

enum StandaloneQwen38MTPResolver {
    static let targetModelID = "EigenLabs/Qwen3.8-27B-4bit"
    static let assistantModelID = "EigenLabs/Qwen3.8-27B-MTP-4bit"
    static let assistantRevision = "329261c5e0b3f9c233485e682cb3b67b88c20a55"

    static func shouldResolve(
        modelID: String,
        mode: MTPMode,
        explicitPath: String?,
        environment: [String: String]
    ) -> Bool {
        guard modelID == targetModelID,
            // The resolver's own id pin (line above) already decided this is
            // the Qwen3.8 target, so the family model-type rule is moot here;
            // nil keeps the pinned-id decision only.
            mode.enablesMTP(forModelID: modelID, modelType: nil),
            explicitPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            SpecDecArtifactFunnel.killSwitchEnabled(environment: environment)
        else { return false }
        return true
    }

    /// Resolve only the immutable assistant snapshot already present in the
    /// Hugging Face cache. No ref lookup, latest-snapshot selection, network
    /// request, or implicit download is permitted.
    static func resolveCached(
        cacheRoot: URL? = ModelScanner.defaultCacheDirectory(),
        stageRoot: URL = SpecDecStore.defaultRoot()
            .appendingPathComponent("standalone-hf", isDirectory: true)
    ) -> SpecDecResolution {
        guard let cacheRoot else {
            return .fallback(
                .artifactNotCached,
                detail: "exact Qwen3.8 MTP snapshot is not downloaded")
        }
        let modelRoot = cacheRoot
            .appendingPathComponent(
                "models--\(assistantModelID.replacingOccurrences(of: "/", with: "--"))",
                isDirectory: true)
            .standardizedFileURL
        let snapshot = modelRoot
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(assistantRevision, isDirectory: true)
            .standardizedFileURL
        guard snapshot.lastPathComponent == assistantRevision,
            isDirectory(snapshot)
        else {
            return .fallback(
                .artifactNotCached,
                detail: "exact Qwen3.8 MTP revision is not downloaded")
        }

        let destination = stageRoot
            .appendingPathComponent("qwen38-mtp-\(assistantRevision)", isDirectory: true)

        let temporary = stageRoot.appendingPathComponent(
            ".qwen38-mtp-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporary, withIntermediateDirectories: true)
            let entries = try FileManager.default.contentsOfDirectory(
                at: snapshot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let selected = entries.filter {
                $0.lastPathComponent == "config.json"
                    || $0.lastPathComponent.hasSuffix(".safetensors")
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard selected.contains(where: { $0.lastPathComponent == "config.json" }),
                selected.contains(where: { $0.lastPathComponent.hasSuffix(".safetensors") })
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let canonicalModelRoot = modelRoot.resolvingSymlinksInPath()
                .standardizedFileURL
            let modelRootPrefix = canonicalModelRoot.path.hasSuffix("/")
                ? canonicalModelRoot.path : canonicalModelRoot.path + "/"
            for source in selected {
                let resolved = source.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(modelRootPrefix),
                    regularFile(resolved)
                else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let target = temporary.appendingPathComponent(source.lastPathComponent)
                do {
                    try FileManager.default.linkItem(at: resolved, to: target)
                } catch {
                    try FileManager.default.copyItem(at: resolved, to: target)
                }
            }
            guard let inspected = SpecDecStore.inspectLocalArtifact(
                path: temporary.path)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.createDirectory(
                at: stageRoot, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                guard let published = SpecDecStore.inspectLocalArtifact(
                    path: destination.path),
                    samePayload(published, inspected)
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return .resolved(pinned(published))
            } catch {
                if let raced = SpecDecStore.inspectLocalArtifact(
                    path: destination.path),
                    samePayload(raced, inspected)
                {
                    try? FileManager.default.removeItem(at: temporary)
                    return .resolved(pinned(raced))
                }
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .fallback(
                .localArtifactInvalid,
                detail: "exact cached Qwen3.8 MTP artifact failed local inspection")
        }
    }

    private static func pinned(_ artifact: SpecDecArtifact) -> SpecDecArtifact {
        artifact.recordingSourceRevision(assistantRevision)
    }

    private static func samePayload(
        _ lhs: SpecDecArtifact,
        _ rhs: SpecDecArtifact
    ) -> Bool {
        lhs.artifactBytes == rhs.artifactBytes
            && lhs.localConfigSHA256 == rhs.localConfigSHA256
            && lhs.localWeightSHA256 == rhs.localWeightSHA256
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path)
        else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
}

extension StandaloneServer {
    func specDecPreparation(
        modelId: String, modelInfo: ModelInfo, modelDirectory: URL? = nil
    ) async -> SpecDecPreparation {
        let environment = ProcessInfo.processInfo.environment
        if StandaloneQwen38MTPResolver.shouldResolve(
            modelID: modelId,
            mode: config.mtpMode,
            explicitPath: config.mtpDrafterPath,
            environment: environment)
        {
            let resolution = StandaloneQwen38MTPResolver.resolveCached()
            if let artifact = resolution.artifact {
                return SpecDecPreparation(
                    artifact: artifact,
                    status: .candidate(artifact))
            }
            return SpecDecPreparation(
                artifact: nil,
                status: .disabled(
                    resolution.reason ?? .artifactNotCached,
                    configured: true))
        }

        return await specDecFunnel.prepare(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: config.mtpMode.enablesMTP(
                    forModelID: modelId, modelType: modelInfo.modelType),
                localPath: config.mtpDrafterPath,
                modelDirectory: modelDirectory,
                // `darkbloom start --local` is coordinator-independent and
                // never auto-downloads an assistant.
                allowDownload: false,
                environment: environment))
    }
}
