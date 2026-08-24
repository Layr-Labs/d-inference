import Foundation

struct RoutedProjectionEvidence: Sendable {
    let scope: String
    let layer: Int
    let role: String
    let rows: Int
    let columns: Int
    let zeroRows: [[Bool]]
    let zeroWeightBK8Fragments: [Int]
    let scalesSHA256: String
    let biasesSHA256: String?
}

struct RoutedLayerSummary: Sendable {
    let scope: String
    let layer: Int
    let expertCount: Int
    let gateZeroRows: Int
    let upZeroRows: Int
    let deadHiddenChannels: Int
    let gateUpZeroMasksEqual: Bool
    let gateUpScalePayloadsEqual: Bool
    let gateUpBiasPayloadsEqual: Bool
    let gateBN32AlignedZeroTiles: Int
    let upBN32AlignedZeroTiles: Int
    let gateBN32CompactionTilesRemoved: Int
    let upBN32CompactionTilesRemoved: Int
    let gateUpBN32TileSlots: Int
    let downBK8DeadActivationFragments: Int
    let downBK8ZeroWeightColumnFragments: Int
    let downBK8FragmentSlots: Int
    let gateUpMACs: Int64
    let downMACs: Int64
    let removableGateUpMACsByBN32Compaction: Int64
    let removableDownMACsByAlignedBK8DeadActivation: Int64
}

struct RoutedModelSummary: Sendable {
    let scope: String
    let layerCount: Int
    let expertCount: Int
    let gateZeroRows: Int
    let upZeroRows: Int
    let deadHiddenChannels: Int
    let unequalGateUpZeroMaskLayers: Int
    let gateUpBN32TileSlots: Int
    let gateUpBN32AlignedZeroTiles: Int
    let gateUpBN32CompactionTilesRemoved: Int
    let downBK8FragmentSlots: Int
    let downBK8DeadActivationFragments: Int
    let downBK8ZeroWeightColumnFragments: Int
    let routedMACs: Int64
    let removableMACs: Int64
    let removableMACFraction: Double
}

final class RoutedTileCollector {
    private var projections: [String: RoutedProjectionEvidence] = [:]

    func add(_ audit: TensorAudit) {
        guard
            let parsed = parseRoutedProjection(audit.tensor.baseName),
            ["gate_proj", "up_proj", "down_proj"].contains(parsed.role)
        else {
            return
        }
        let key = "\(parsed.scope)#\(parsed.layer)#\(parsed.role)"
        projections[key] = RoutedProjectionEvidence(
            scope: parsed.scope,
            layer: parsed.layer,
            role: parsed.role,
            rows: audit.tensor.rows,
            columns: audit.tensor.columns,
            zeroRows: audit.matrices.map(\.zeroRows),
            zeroWeightBK8Fragments: audit.matrices.map {
                $0.columnBlockZeroCounts[8] ?? 0
            },
            scalesSHA256: audit.scalesSHA256,
            biasesSHA256: audit.biasesSHA256
        )
    }

    func summarize() throws -> ([RoutedLayerSummary], [RoutedModelSummary]) {
        let layerKeys = Set(projections.values.map { "\($0.scope)#\($0.layer)" })
        var layers: [RoutedLayerSummary] = []
        for layerKey in layerKeys.sorted(by: layerKeyLessThan) {
            let pieces = layerKey.split(separator: "#")
            let scope = String(pieces[0])
            let layer = Int(pieces[1])!
            guard
                let gate = projections["\(scope)#\(layer)#gate_proj"],
                let up = projections["\(scope)#\(layer)#up_proj"],
                let down = projections["\(scope)#\(layer)#down_proj"]
            else {
                throw AuditError.invalid(
                    "routed layer \(scope)/\(layer) lacks gate, up, or down evidence"
                )
            }
            guard
                gate.zeroRows.count == up.zeroRows.count,
                gate.zeroRows.count == down.zeroRows.count,
                gate.rows == up.rows,
                down.columns == gate.rows
            else {
                throw AuditError.invalid(
                    "routed layer \(scope)/\(layer) has incompatible projection shapes"
                )
            }

            var gateZeroRows = 0
            var upZeroRows = 0
            var deadHiddenChannels = 0
            var masksEqual = true
            var gateAligned = 0
            var upAligned = 0
            var gateCompacted = 0
            var upCompacted = 0
            var downDeadBK8 = 0
            var downZeroWeightBK8 = 0

            for expert in gate.zeroRows.indices {
                let gateMask = gate.zeroRows[expert]
                let upMask = up.zeroRows[expert]
                gateZeroRows += gateMask.reduce(0) { $0 + ($1 ? 1 : 0) }
                upZeroRows += upMask.reduce(0) { $0 + ($1 ? 1 : 0) }
                if gateMask != upMask { masksEqual = false }

                let deadMask = zip(gateMask, upMask).map { $0 || $1 }
                deadHiddenChannels += deadMask.reduce(0) { $0 + ($1 ? 1 : 0) }
                gateAligned += alignedTrueBlocks(gateMask, width: 32)
                upAligned += alignedTrueBlocks(upMask, width: 32)
                downDeadBK8 += alignedTrueBlocks(deadMask, width: 8)

                let gateLive = gateMask.reduce(0) { $0 + ($1 ? 0 : 1) }
                let upLive = upMask.reduce(0) { $0 + ($1 ? 0 : 1) }
                gateCompacted += gate.rows / 32 - divideRoundUp(gateLive, 32)
                upCompacted += up.rows / 32 - divideRoundUp(upLive, 32)
                downZeroWeightBK8 += down.zeroWeightBK8Fragments[expert]
            }

            let expertCount = gate.zeroRows.count
            let gateUpMACs =
                Int64(expertCount)
                * Int64(gate.rows * gate.columns + up.rows * up.columns)
            let downMACs = Int64(expertCount) * Int64(down.rows * down.columns)
            let removableGateUp =
                Int64(gateCompacted * 32 * gate.columns)
                + Int64(upCompacted * 32 * up.columns)
            let removableDown = Int64(downDeadBK8 * 8 * down.rows)
            layers.append(
                RoutedLayerSummary(
                    scope: scope,
                    layer: layer,
                    expertCount: expertCount,
                    gateZeroRows: gateZeroRows,
                    upZeroRows: upZeroRows,
                    deadHiddenChannels: deadHiddenChannels,
                    gateUpZeroMasksEqual: masksEqual,
                    gateUpScalePayloadsEqual:
                        gate.scalesSHA256 == up.scalesSHA256,
                    gateUpBiasPayloadsEqual:
                        gate.biasesSHA256 == up.biasesSHA256,
                    gateBN32AlignedZeroTiles: gateAligned,
                    upBN32AlignedZeroTiles: upAligned,
                    gateBN32CompactionTilesRemoved: gateCompacted,
                    upBN32CompactionTilesRemoved: upCompacted,
                    gateUpBN32TileSlots:
                        expertCount * (gate.rows / 32 + up.rows / 32),
                    downBK8DeadActivationFragments: downDeadBK8,
                    downBK8ZeroWeightColumnFragments: downZeroWeightBK8,
                    downBK8FragmentSlots: expertCount * down.columns / 8,
                    gateUpMACs: gateUpMACs,
                    downMACs: downMACs,
                    removableGateUpMACsByBN32Compaction: removableGateUp,
                    removableDownMACsByAlignedBK8DeadActivation: removableDown
                )
            )
        }

        let scopes = Set(layers.map(\.scope))
        let models = scopes.sorted().map { scope -> RoutedModelSummary in
            let selected = layers.filter { $0.scope == scope }
            let routedMACs = selected.reduce(Int64(0)) {
                $0 + $1.gateUpMACs + $1.downMACs
            }
            let removableMACs = selected.reduce(Int64(0)) {
                $0 + $1.removableGateUpMACsByBN32Compaction
                    + $1.removableDownMACsByAlignedBK8DeadActivation
            }
            return RoutedModelSummary(
                scope: scope,
                layerCount: selected.count,
                expertCount: selected.reduce(0) { $0 + $1.expertCount },
                gateZeroRows: selected.reduce(0) { $0 + $1.gateZeroRows },
                upZeroRows: selected.reduce(0) { $0 + $1.upZeroRows },
                deadHiddenChannels:
                    selected.reduce(0) { $0 + $1.deadHiddenChannels },
                unequalGateUpZeroMaskLayers:
                    selected.reduce(0) {
                        $0 + ($1.gateUpZeroMasksEqual ? 0 : 1)
                    },
                gateUpBN32TileSlots:
                    selected.reduce(0) { $0 + $1.gateUpBN32TileSlots },
                gateUpBN32AlignedZeroTiles:
                    selected.reduce(0) {
                        $0 + $1.gateBN32AlignedZeroTiles
                            + $1.upBN32AlignedZeroTiles
                    },
                gateUpBN32CompactionTilesRemoved:
                    selected.reduce(0) {
                        $0 + $1.gateBN32CompactionTilesRemoved
                            + $1.upBN32CompactionTilesRemoved
                    },
                downBK8FragmentSlots:
                    selected.reduce(0) { $0 + $1.downBK8FragmentSlots },
                downBK8DeadActivationFragments:
                    selected.reduce(0) {
                        $0 + $1.downBK8DeadActivationFragments
                    },
                downBK8ZeroWeightColumnFragments:
                    selected.reduce(0) {
                        $0 + $1.downBK8ZeroWeightColumnFragments
                    },
                routedMACs: routedMACs,
                removableMACs: removableMACs,
                removableMACFraction:
                    routedMACs == 0 ? 0 : Double(removableMACs) / Double(routedMACs)
            )
        }
        return (layers, models)
    }
}

private func parseRoutedProjection(
    _ baseName: String
) -> (scope: String, layer: Int, role: String)? {
    let components = baseName.split(separator: ".").map(String.init)
    if
        components.count >= 7,
        components[0] == "language_model",
        components[1] == "model",
        components[2] == "layers",
        let layer = Int(components[3]),
        components[4] == "mlp",
        components[5] == "switch_mlp"
    {
        return ("language_model", layer, components[6])
    }
    if
        components.count >= 6,
        components[0] == "mtp",
        components[1] == "layers",
        let layer = Int(components[2]),
        components[3] == "mlp",
        components[4] == "switch_mlp"
    {
        return ("mtp", layer, components[5])
    }
    return nil
}

private func alignedTrueBlocks(_ mask: [Bool], width: Int) -> Int {
    guard mask.count % width == 0 else { return 0 }
    var result = 0
    for start in stride(from: 0, to: mask.count, by: width) {
        if mask[start..<(start + width)].allSatisfy({ $0 }) {
            result += 1
        }
    }
    return result
}

private func divideRoundUp(_ value: Int, _ divisor: Int) -> Int {
    (value + divisor - 1) / divisor
}

private func layerKeyLessThan(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.split(separator: "#")
    let right = rhs.split(separator: "#")
    if left[0] != right[0] { return left[0] < right[0] }
    return Int(left[1])! < Int(right[1])!
}
