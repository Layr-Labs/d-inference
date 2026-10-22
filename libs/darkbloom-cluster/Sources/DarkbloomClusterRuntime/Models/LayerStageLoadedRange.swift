import Foundation
import MLXNN

/// After a stage loads, the layers it actually holds are compared with the
/// layers its plan gave it. The owner's planner does this (oMLX U#3638: a
/// GLM-5.2 rank loaded 39 of 39 layers for a 26/52 plan after a 432 GB load;
/// a MiniMax-M3 rank loaded 30 of 60 for a 14-layer plan). The verified
/// loader already holds every tensor to the plan's inventory; this checks the
/// constructed module tree itself, by the layer indices its parameters carry.
enum LayerStageLoadedRange {
    /// The local layer index of a parameter name (`... .layers.<n>. ...`),
    /// or nil for a parameter outside the decoder layers. A speculative head's
    /// own layers (under an `mtp` component) are not the stage's.
    static func layerIndex(parameterName name: String) -> Int? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.contains("mtp") else { return nil }
        for index in parts.indices.dropLast() where parts[index] == "layers" {
            if let layer = Int(parts[index + 1]), String(layer) == String(parts[index + 1]) { return layer }
        }
        return nil
    }

    /// The local layer indices the names hold parameters for.
    static func layers(parameterNames: [String]) -> Set<Int> {
        Set(parameterNames.compactMap(layerIndex(parameterName:)))
    }

    /// Throws unless the loaded parameters cover exactly local layers
    /// `0..<plannedLayers`; returns the log line that records the range.
    static func verify(parameterNames: [String], plannedLayers: Int, firstGlobalLayer: Int, rank: Int,
                       model: String) throws -> String {
        let held = layers(parameterNames: parameterNames)
        guard plannedLayers > 0, held == Set(0..<plannedLayers) else {
            let shown = held.sorted().prefix(8).map(String.init).joined(separator: ",")
            throw ProbeError("Rank \(rank) loaded parameters for \(held.count) layers (\(shown)\(held.count > 8 ? ",..." : "")) "
                + "where its plan gives it \(plannedLayers), from global layer \(firstGlobalLayer)")
        }
        return "darkbloom-stage-loaded-range-v1 rank=\(rank) model=\(model) first=\(firstGlobalLayer)"
            + " end=\(firstGlobalLayer + plannedLayers) layers=\(held.count)"
    }

    static func verify(model module: Module, plannedLayers: Int, firstGlobalLayer: Int, rank: Int,
                       model: String) throws -> String {
        try verify(parameterNames: module.parameters().flattened().map(\.0), plannedLayers: plannedLayers,
                   firstGlobalLayer: firstGlobalLayer, rank: rank, model: model)
    }
}
