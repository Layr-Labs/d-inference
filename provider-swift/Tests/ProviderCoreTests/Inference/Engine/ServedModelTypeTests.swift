// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Served model types: the engine's supported set")
struct ServedModelTypeTests {
    /// How `EngineV2SupportedModels.isSupported(modelType:)` answers one type.
    private enum Admission {
        /// In any letter case, with surrounding whitespace.
        case byType
        /// Only as config.json spells it.
        case byExactDeclaration
        /// Never by its type: `isSupported(model:)` checks the model id.
        case byIdentityOnly
    }

    private static let admissions: [String: Admission] = [
        "gpt_oss": .byType, "gemma4": .byType, "gemma4_text": .byType, "diffusion_gemma": .byType,
        "qwen3_5": .byType, "qwen3_5_moe": .byType, "prism_hadamard_qwen35": .byType, "qwen3_vl_moe": .byType,
        "qwen4_exp": .byType, "qwen4_exp_text": .byType,
        "mimo_v2": .byExactDeclaration, "flint": .byExactDeclaration,
        "glm5_next": .byIdentityOnly, "nemotron_h": .byIdentityOnly, "nemotron_h_omni": .byIdentityOnly,
    ]

    private func isSupported(_ modelType: String?) -> Bool {
        EngineV2SupportedModels.isSupported(modelType: modelType)
    }

    @Test("the enum holds exactly the admitted types, each as config.json declares it")
    func closedList() {
        #expect(Set(ServedModelType.allCases.map(\.rawValue)) == Set(Self.admissions.keys))
        // The supported-set lookup lowercases and trims before it reads a raw
        // value, so any other spelling of a case could never be admitted.
        for type in ServedModelType.allCases {
            let declared = type.rawValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(type.rawValue == declared, "\(type)")
        }
    }

    @Test("every type is admitted by its declaration, its respellings and its neighbours as this table says")
    func supportedSetBySpelling() {
        for (type, admission) in Self.admissions {
            #expect(isSupported(type) == (admission != .byIdentityOnly), "\(type)")
            let respellings = [
                type.uppercased(), " \(type) ", "\t\(type)\n", type.prefix(1).uppercased() + type.dropFirst(),
            ]
            for respelled in respellings {
                #expect(isSupported(respelled) == (admission == .byType), "\(respelled.debugDescription)")
            }
            let neighbours = [
                type + "_x", "x_" + type, type + "2", String(type.dropLast()),
                type.replacingOccurrences(of: "_", with: "-"),
            ]
            for neighbour in neighbours where Self.admissions[neighbour] == nil {
                #expect(!isSupported(neighbour), "\(neighbour)")
            }
        }
    }

    @Test("a missing, empty or unlisted type is unsupported")
    func unlistedTypes() {
        let unlisted: [String?] = [
            nil, "", "   ", "llama", "gemma", "gemma3", "gemma4_assistant", "gemma4_vision", "qwen3", "qwen3_vl",
            "qwen3_moe", "glm5_next_text", "glm5_next_mtp", "mimo_v2_nextn", "nemotron_h_attention_moe", "flint_mtp",
        ]
        for modelType in unlisted {
            #expect(!isSupported(modelType), "\(modelType.debugDescription)")
        }
    }
}
