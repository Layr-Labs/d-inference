import Foundation

enum Gemma4ForwardTarget: Equatable {
    case fullReference
    case stage(Int)
}

struct Gemma4SelectedTensor {
    let source: LayerStageSourceTensor
    let localName: String
    let dtype: Gemma4ForwardDType
    var sourceDType: String { dtype.nativeSourceName }
    var loadedDType: String { dtype.nativeLoadedName }

    init(source: LayerStageSourceTensor, localName: String) throws {
        self.source = source; self.localName = localName
        dtype = try Gemma4ForwardDType(safetensorsName: source.layout.sourceDType)
    }
}

/// One exact whole text inventory or one selected rank; never an expert slice.
enum Gemma4ForwardSelection {
    static func make(plan: Gemma4LayerStagePlan, target: Gemma4ForwardTarget) throws -> [Gemma4SelectedTensor] {
        let result: [Gemma4SelectedTensor]
        switch target {
        case .fullReference:
            let excluded = Set(plan.artifact.excludedSourceNames)
            result = try plan.artifact.sources.filter { !excluded.contains($0.layout.canonicalName) }.map {
                try .init(source: $0, localName: $0.layout.canonicalName)
            }
        case .stage(let rank):
            guard plan.stages.indices.contains(rank) else { throw ProbeError("Unknown Gemma stage") }
            result = try plan.mappings.flatMap { mapping in
                try mapping.destinations.filter { $0.rank == rank }.map {
                    try Gemma4SelectedTensor(source: mapping.source, localName: $0.localName)
                }
            }
        }
        guard !result.isEmpty, Set(result.map(\.localName)).count == result.count else {
            throw ProbeError("Registered Gemma selected destinations collide")
        }
        return result.sorted { $0.localName < $1.localName }
    }
}
