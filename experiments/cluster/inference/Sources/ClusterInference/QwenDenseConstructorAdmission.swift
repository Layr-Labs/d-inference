import Foundation

/// Closed metadata-probe admission. This is not a weight-loading or execution
/// capability. It admits only the two exact retained inputs and default halves.
struct QwenDenseConstructorAdmission {
    let specification: QwenDenseRegisteredSpecification
    let configuration: Data, manifest: Data
    let plan: QwenLayerStagePlan
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let scope = "registered_dense_constructor_metadata_only_v1"
    let weightMaterializationAuthorized = false, forwardExecutionAuthorized = false
    let independentResourceAdmissionEstablished = false, providerEligibilityEstablished = false

    private init(specification: QwenDenseRegisteredSpecification, configuration: Data, manifest: Data,
                 plan: QwenLayerStagePlan, arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt) {
        self.specification = specification; self.configuration = configuration; self.manifest = manifest
        self.plan = plan; self.arithmetic = arithmetic
    }

    static func admit(model: QwenRegisteredDenseModel, configuration: Data, manifest: Data,
                      environment: [String: String]) throws -> Self {
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count),
              let spec = QwenDenseRegisteredSpecification.all.first(where: { $0.model == model }),
              QwenDenseProfileIdentity.sha256(configuration) == spec.configurationSHA256,
              QwenDenseProfileIdentity.sha256(manifest) == spec.manifestSHA256 else {
            throw ProbeError("Constructor probe requires the exact selected registered configuration and raw manifest")
        }
        let declared = try JSONDecoder().decode(CheckpointManifest.self, from: manifest)
        guard declared.aggregate_sha256 == spec.artifactSHA256, declared.file_count == spec.manifestFileCount,
              declared.files.count == spec.manifestFileCount,
              Set(declared.files.map(\.path)).count == spec.manifestFileCount,
              declared.total_size_bytes == spec.manifestBytes,
              try QwenLongPrefillCheckedBytes.sum(declared.files.map(\.size_bytes)) == spec.manifestBytes,
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == spec.configurationSHA256 else {
            throw ProbeError("Constructor probe manifest identity differs")
        }
        let plan = try QwenLayerStagePlan(configuration: configuration,
            ranges: [0..<(spec.layers / 2), (spec.layers / 2)..<spec.layers])
        guard plan.layers == spec.layers, plan.interval == 4 else {
            throw ProbeError("Constructor probe registered Plan geometry differs")
        }
        return try .init(specification: spec, configuration: configuration, manifest: manifest,
            plan: plan, arithmetic: QwenLongPrefillArithmeticEnvironment.admit(environment))
    }
}
