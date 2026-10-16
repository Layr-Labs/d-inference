import Foundation
import ProviderCoreFoundation

/// Local-only authority. This must never be folded into EngineV2SupportedModels,
/// whose readers advertise coordinator capacity and select default cohorts.
public enum GLM5NextLocalQualification {
    public static let environmentKey = "DARKBLOOM_EXPERIMENTAL_GLM5_NEXT"
    public static let modelID = "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp"

    struct Selection: Decodable {
        let catalog: CatalogModel
        let manifest: ModelManifest
        let expectedAggregateSHA256: String
        let maximumContextLength: Int?

        private enum CodingKeys: String, CodingKey {
            case catalog, manifest, expectedAggregateSHA256, maximumContextLength, tokenizer
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // The raw-discovery LOAD quotation covers only a tokenizer shipped
            // in the weight snapshot. Refuse the retired composition field
            // instead of silently ignoring it.
            guard !values.contains(.tokenizer) else {
                throw GLM5NextManagedLoadError.metadata(
                    "separate tokenizer selection is unsupported; use the tokenizer shipped in the pinned weight snapshot")
            }
            catalog = try values.decode(CatalogModel.self, forKey: .catalog)
            manifest = try values.decode(ModelManifest.self, forKey: .manifest)
            expectedAggregateSHA256 = try values.decode(String.self, forKey: .expectedAggregateSHA256)
            maximumContextLength = try values.decodeIfPresent(Int.self, forKey: .maximumContextLength)
        }
    }

    static func selection(environment: [String: String]) throws -> Selection {
        guard let path = environment[environmentKey], path.hasPrefix("/") else {
            throw GLM5NextManagedLoadError.managedLoadRequired
        }
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue > 0,
            size.intValue <= 4 << 20 else {
            throw GLM5NextManagedLoadError.invalidManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let selected = try decoder.decode(Selection.self, from: Data(contentsOf: url))
        try validate(modelID: selected.catalog.id, aggregate: selected.manifest.aggregateSHA256,
            expectedAggregate: selected.expectedAggregateSHA256)
        guard selected.catalog.aggregateSHA256 == selected.expectedAggregateSHA256,
            let source = selected.catalog.huggingFaceArtifact, source.repoID == modelID else {
            throw GLM5NextManagedLoadError.identityMismatch
        }
        _ = try source.downloadURL(for: "config.json")
        try ModelCatalogClient.validateManifestBounds(selected.manifest)
        try ModelDownloader.validateArtifactManifest(selected.manifest, model: selected.catalog)
        return selected
    }

    static let defaultMaximumContextLength = 4096

    static func validate(modelID: String, aggregate: String, expectedAggregate: String) throws {
        guard modelID == Self.modelID, aggregate == expectedAggregate,
            aggregate.utf8.count == 64,
            aggregate.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GLM5NextManagedLoadError.identityMismatch
        }
    }

    public static func isSupportedLocally(
        model: ModelInfo, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard model.modelType == "glm5_next" else {
            return EngineV2SupportedModels.isSupported(model: model)
        }
        return (try? requireLocalSelection(model: model, environment: environment)) != nil
    }

    /// Why an exact `glm5_next` model is not locally supported, for operator
    /// diagnostics. Nil for supported models and for every other family.
    public static func localSelectionRefusal(
        model: ModelInfo, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard model.modelType == "glm5_next" else { return nil }
        do {
            try requireLocalSelection(model: model, environment: environment)
            return nil
        } catch GLM5NextManagedLoadError.managedLoadRequired {
            return "set \(environmentKey) to the absolute path of a local GLM selection file"
        } catch GLM5NextManagedLoadError.identityMismatch {
            return "the local GLM selection does not pin \(modelID) with a matching aggregate SHA-256"
        } catch GLM5NextManagedLoadError.invalidManifest {
            return "the local GLM selection must be a non-empty regular file of at most 4 MiB"
        } catch GLM5NextManagedLoadError.metadata(let reason) {
            return "the local GLM selection is invalid: \(reason)"
        } catch {
            return "the local GLM selection is invalid: \(error)"
        }
    }

    private static func requireLocalSelection(model: ModelInfo, environment: [String: String]) throws {
        guard model.id == modelID else { throw GLM5NextManagedLoadError.identityMismatch }
        let selected = try selection(environment: environment)
        guard selected.catalog.id == model.id,
            model.weightHash == nil || model.weightHash == selected.expectedAggregateSHA256 else {
            throw GLM5NextManagedLoadError.identityMismatch
        }
    }

    public static func partition(
        _ models: [ModelInfo], environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (supported: [ModelInfo], unsupported: [ModelInfo]) {
        var supported: [ModelInfo] = []
        var unsupported: [ModelInfo] = []
        for model in models {
            if isSupportedLocally(model: model, environment: environment) { supported.append(model) }
            else { unsupported.append(model) }
        }
        return (supported, unsupported)
    }

    /// One selection read per load: the plan and its execution bound travel
    /// together so a concurrently edited selection file cannot mix them.
    static func resolveLocalPlan(
        modelID: String, directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GLM5NextServingPlan {
        let selected = try selection(environment: environment)
        try validate(modelID: modelID, aggregate: selected.manifest.aggregateSHA256,
            expectedAggregate: selected.expectedAggregateSHA256)
        let plan = try GLM5NextArtifactPlan.inspect(
            directory: directory, catalog: selected.catalog, manifest: selected.manifest)
        try requireShippedTemplate(plan)
        return .init(plan: plan,
            maximumContextLength: selected.maximumContextLength ?? defaultMaximumContextLength)
    }

    /// GLM prompt rules describe exactly the template shipped in the pinned
    /// artifact. Another template, even one that renders, gets no GLM rules.
    /// Every serving plan resolver must call this before loading.
    static func requireShippedTemplate(_ plan: GLM5NextArtifactPlan) throws {
        guard plan.usesShippedPromptTemplate else {
            throw GLM5NextManagedLoadError.metadata(
                "unrecognized GLM chat template; only the template shipped in \(modelID) is supported")
        }
    }

    /// Explicit isolated qualification harness entry. It does not alter either
    /// local discovery or coordinator support and still verifies bytes on LOAD.
    static func plan(directory: URL, manifestURL: URL, source: HuggingFaceArtifact,
        expectedAggregateSHA256: String) throws -> GLM5NextArtifactPlan {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
        try validate(modelID: manifest.modelID, aggregate: manifest.aggregateSHA256,
            expectedAggregate: expectedAggregateSHA256)
        guard source.repoID == modelID else { throw GLM5NextManagedLoadError.identityMismatch }
        let catalog = CatalogModel(id: manifest.modelID, s3Name: "local-qualification",
            displayName: "Local GLM qualification", sizeGb: Double(manifest.totalSizeBytes) / 1e9,
            version: manifest.version, r2Prefix: manifest.r2Prefix, huggingFaceArtifact: source,
            aggregateSHA256: manifest.aggregateSHA256, totalSizeBytes: manifest.totalSizeBytes,
            fileCount: manifest.fileCount)
        return try GLM5NextArtifactPlan.inspect(directory: directory, catalog: catalog, manifest: manifest)
    }
}
