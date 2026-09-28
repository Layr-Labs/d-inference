import Foundation

enum QwenCandidateExport {
    static let maximumConfigurationBytes = 1_048_576
    static let maximumNamesBytes = 2_097_152
    static let maximumNames = 8_192
    static let maximumNameBytes = 512
    static let maximumOutputBytes = 33_554_432

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func make(configuration: Data, canonicalNamesJSON: Data,
                     expectedConfigurationSHA256: String, expectedCanonicalNamesSHA256: String)
        throws -> QwenCandidateExportCatalog {
        guard !configuration.isEmpty, configuration.count <= maximumConfigurationBytes,
              !canonicalNamesJSON.isEmpty, canonicalNamesJSON.count <= maximumNamesBytes,
              isSHA256(expectedConfigurationSHA256), isSHA256(expectedCanonicalNamesSHA256),
              sha256(configuration) == expectedConfigurationSHA256,
              sha256(canonicalNamesJSON) == expectedCanonicalNamesSHA256 else {
            throw ProbeError("Candidate input bytes or raw SHA-256 pins differ")
        }
        try validateCandidateExportConfigurationJSON(configuration)
        try validateWorkerJSON(canonicalNamesJSON)
        let names = try JSONDecoder().decode([String].self, from: canonicalNamesJSON)
        guard !names.isEmpty, names.count <= maximumNames, Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumNameBytes
                  && $0.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) }) else {
            throw ProbeError("Candidate canonical names exceed bounds or contain duplicates/control bytes")
        }
        // This call owns all model, cut, quantization and ownership predicates.
        // Do not replace it with exporter-side geometry or name guesses.
        let native = try QwenLayerStageCandidates.enumerate(configuration: configuration,
            canonicalSourceNames: names, activeMTP: false)
        let candidates = native.map { candidate in
            QwenCandidateExportCandidate(cut: candidate.cut, planFingerprint: candidate.plan.fingerprint,
                stages: candidate.ownership.map { owner in
                    let stage = candidate.plan.stages[owner.stageIndex]
                    return QwenCandidateExportStage(stageIndex: owner.stageIndex,
                        sourceLayerRange: [stage.sourceRange.lowerBound, stage.sourceRange.upperBound],
                        stageFingerprint: stage.fingerprint,
                        constructionConfigurationSHA256: sha256(stage.constructionConfiguration),
                        parameters: owner.parameters,
                        state: owner.state.map { .init(layer: $0.layer, components: $0.components.map(\.rawValue)) },
                        activeModuleRoots: stage.activeModuleRoots, inertModules: stage.inertModules,
                        parameterCount: owner.parameters.count, stateLayerCount: owner.state.count)
                }, excludedCanonicalSourceNames: candidate.excludedCanonicalSourceNames)
        }
        return QwenCandidateExportCatalog(sourceConfigurationSHA256: sha256(configuration),
            canonicalNamesRawSHA256: sha256(canonicalNamesJSON),
            canonicalNamesSHA256: sha256(try QwenCandidateExportEncoding.data(names.sorted())),
            canonicalNameCount: names.count, candidates: candidates)
    }
}
