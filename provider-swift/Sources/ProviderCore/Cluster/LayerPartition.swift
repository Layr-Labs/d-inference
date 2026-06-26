/// LayerPartition -- memory-weighted assignment of transformer layers to cluster
/// nodes for pipeline parallelism.
///
/// Reimplements exo's `allocate_layers_proportionally` (placement_utils.py:47)
/// in Swift: each node receives a contiguous, half-open layer interval
/// `[start, end)`, sized in proportion to its available RAM, with a
/// largest-remainder rule so the layer counts sum exactly to `totalLayers` and
/// every participating node gets at least one layer.
///
/// Pure arithmetic -- no MLX, no IO -- so it is unit-testable on one machine and
/// is the deterministic input the distributed engine uses to decide which
/// layers each rank loads. The node ordering passed in is the ring order; the
/// resulting intervals are contiguous and cover `0..<totalLayers` exactly.

import Foundation

public struct LayerInterval: Equatable, Sendable {
    public let nodeId: String
    /// Inclusive start layer index.
    public let start: Int
    /// Exclusive end layer index.
    public let end: Int

    public var count: Int { end - start }
    /// Canonical "start..end" string used as AEAD layer-range context.
    public var rangeString: String { "\(start)..\(end)" }

    public init(nodeId: String, start: Int, end: Int) {
        self.nodeId = nodeId
        self.start = start
        self.end = end
    }
}

public enum LayerPartitionError: Error, Equatable, Sendable {
    case noNodes
    case tooManyNodesForLayers(nodes: Int, layers: Int)
    case nonPositiveWeight(nodeId: String)
}

public enum LayerPartition {
    /// A node and the memory weight used to size its share.
    public struct NodeWeight: Equatable, Sendable {
        public let nodeId: String
        /// Available memory in bytes (or any positive proportional weight).
        public let weightBytes: UInt64
        public init(nodeId: String, weightBytes: UInt64) {
            self.nodeId = nodeId
            self.weightBytes = weightBytes
        }
    }

    /// Partition `totalLayers` across `nodes` (given in ring order) in
    /// proportion to each node's weight, largest-remainder, min 1 layer/node.
    public static func partition(totalLayers: Int, nodes: [NodeWeight]) throws -> [LayerInterval] {
        guard !nodes.isEmpty else { throw LayerPartitionError.noNodes }
        guard totalLayers >= nodes.count else {
            throw LayerPartitionError.tooManyNodesForLayers(nodes: nodes.count, layers: totalLayers)
        }
        for n in nodes where n.weightBytes == 0 {
            throw LayerPartitionError.nonPositiveWeight(nodeId: n.nodeId)
        }

        let totalWeight = nodes.reduce(0.0) { $0 + Double($1.weightBytes) }

        // Ideal (fractional) share per node, then floor with min-1.
        var counts = [Int](repeating: 0, count: nodes.count)
        var remainders = [(idx: Int, frac: Double)]()
        var assigned = 0
        for (i, n) in nodes.enumerated() {
            let ideal = Double(totalLayers) * Double(n.weightBytes) / totalWeight
            let floored = max(1, Int(ideal.rounded(.down)))
            counts[i] = floored
            assigned += floored
            remainders.append((i, ideal - Double(Int(ideal.rounded(.down)))))
        }

        // Reconcile to exactly totalLayers.
        if assigned > totalLayers {
            // Over-assigned (min-1 inflation on tiny nodes): trim from the
            // nodes with the most layers, never below 1.
            var over = assigned - totalLayers
            let order = counts.enumerated().sorted { $0.element > $1.element }.map(\.offset)
            var oi = 0
            while over > 0 {
                let idx = order[oi % order.count]
                if counts[idx] > 1 { counts[idx] -= 1; over -= 1 }
                oi += 1
                // Safety: if every node is at 1 we cannot trim further; the
                // totalLayers >= nodes.count guard guarantees this terminates.
                if oi > order.count * (totalLayers + 1) { break }
            }
        } else if assigned < totalLayers {
            // Under-assigned: hand out the leftover by largest fractional part.
            var remaining = totalLayers - assigned
            for (idx, _) in remainders.sorted(by: { $0.frac > $1.frac }) {
                if remaining == 0 { break }
                counts[idx] += 1
                remaining -= 1
            }
        }

        // Materialize contiguous intervals in ring order.
        var intervals = [LayerInterval]()
        var cursor = 0
        for (i, n) in nodes.enumerated() {
            let end = cursor + counts[i]
            intervals.append(LayerInterval(nodeId: n.nodeId, start: cursor, end: end))
            cursor = end
        }
        return intervals
    }
}
