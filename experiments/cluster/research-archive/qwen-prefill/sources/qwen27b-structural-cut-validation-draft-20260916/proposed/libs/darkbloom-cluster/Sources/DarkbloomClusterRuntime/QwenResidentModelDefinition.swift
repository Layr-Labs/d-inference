import Foundation

/// Closed model/profile geometry shared by ordinary admission and the explicit
/// native-validation entry. Describing a model grants no execution permission.
struct QwenResidentModelDefinition {
    static let nineBCuts = [4, 8, 12, 16]
    static let nineBProfileID = "registered_qwen35_9b_greedy_generation_v1"
    let specification: QwenDenseRegisteredSpecification
    let profileID: String
    let supportedCuts: [Int]
    let supportsLookahead: Bool

    init(model: QwenRegisteredDenseModel) throws {
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == model }) else {
            throw QwenDenseProfileError("Unknown registered resident model")
        }
        self.specification = specification
        switch model {
        case .qwen35NineB:
            profileID = Self.nineBProfileID
            supportedCuts = Self.nineBCuts
            supportsLookahead = true
        case .qwen38TwentySevenB:
            profileID = "registered_qwen38_27b_greedy_generation_v1"
            // Explicit native validation follows the registered geometry's
            // whole-interval partitions. This is not a public capability or a
            // memory/performance qualification for any of those partitions.
            let geometry = try specification.expectedGeometry()
            supportedCuts = try QwenLayerStageCandidates.structuralCuts(layerCount: geometry.layers,
                fullAttentionInterval: geometry.fullAttentionInterval)
            supportsLookahead = false
        }
        let geometry = try specification.expectedGeometry()
        let legal = try QwenLayerStageCandidates.structuralCuts(layerCount: geometry.layers,
            fullAttentionInterval: geometry.fullAttentionInterval)
        guard supportedCuts == Array(Set(supportedCuts)).sorted(),
              supportedCuts.allSatisfy(legal.contains) else {
            throw QwenDenseProfileError("Resident candidate cuts differ from registered layer geometry")
        }
    }

    /// Only the unqualified model receives an extended metadata planning scope.
    /// These fields join its metadata fingerprint; the 9B identity stays exact.
    var planningScopeFields: [String] {
        specification.model == .qwen38TwentySevenB
            ? ["resident-native-validation-planning-v1", "cuts=" + supportedCuts.map(String.init).joined(separator: ",")]
            : []
    }
}
