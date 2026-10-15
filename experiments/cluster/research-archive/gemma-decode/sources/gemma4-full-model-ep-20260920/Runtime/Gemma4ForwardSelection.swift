import Foundation

enum Gemma4ForwardTarget: Equatable {
    case fullReference
    case stage(Int)
    case expertParallel(Gemma4ExpertPartition)
}

struct Gemma4SelectedTensor {
    let source: LayerStageSourceTensor
    let localName: String
    let dtype: Gemma4ForwardDType
    let selection: TensorSelection
    let selectedShape: [Int]
    let selectedByteCount: Int
    var sourceDType: String { dtype.nativeSourceName }
    var loadedDType: String { dtype.nativeLoadedName }

    init(source: LayerStageSourceTensor, localName: String, selection: TensorSelection = .all) throws {
        self.source = source; self.localName = localName
        dtype = try Gemma4ForwardDType(safetensorsName: source.layout.sourceDType)
        self.selection = selection
        selectedShape = try selection.resultShape(source.layout.shape)
        let sourceElements = try QwenLongPrefillCheckedBytes.product(source.layout.shape)
        guard sourceElements > 0, source.layout.byteCount % sourceElements == 0 else {
            throw ProbeError("Gemma selected source byte width differs")
        }
        selectedByteCount = try QwenLongPrefillCheckedBytes.product(
            selectedShape + [source.layout.byteCount / sourceElements])
    }
}

/// Original full/stage selection stays whole-tensor; explicit EP selects axis0 only.
enum Gemma4ForwardSelection {
    static func make(plan: Gemma4LayerStagePlan, target: Gemma4ForwardTarget) throws -> [Gemma4SelectedTensor] {
        let result: [Gemma4SelectedTensor]
        switch target {
        case .fullReference:
            let excluded = Set(plan.artifact.excludedSourceNames)
            result = try plan.artifact.sources.filter { !excluded.contains($0.layout.canonicalName) }.map {
                try .init(source: $0, localName: $0.layout.canonicalName)
            }
        case .expertParallel(let partition):
            result = try Gemma4ExpertSelection.make(plan: plan, partition: partition)
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
