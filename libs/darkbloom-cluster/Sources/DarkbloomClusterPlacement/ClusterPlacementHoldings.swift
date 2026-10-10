import DarkbloomClusterProtocol
import Foundation

/// What each Mac holds while a session of one placement is up: which layers
/// and how many bytes of weights. It is the plan's figure, computed from the
/// artifact's layout by the rule the planner uses for a rank's weights, so
/// the status view and the plan cannot say two different things. It is not a
/// measurement of what a worker has loaded.
public struct ClusterPlacementHoldings: Codable, Equatable, Sendable {
    public struct Rank: Codable, Equatable, Sendable {
        public let rank: Int
        /// The member's label, as the setup or the plan names it.
        public let label: String
        public let firstLayer: Int
        public let endLayer: Int
        /// True for the last rank of a phase split, which also loads every
        /// earlier layer so that it can decode alone.
        public let holdsEveryEarlierLayer: Bool
        public let weightsBytes: Int
        /// That Mac's memory, when the caller knows it; shown beside the
        /// share so a small share on a large Mac is not read as nothing.
        public let physicalMemoryBytes: Int?
        /// Set by a view that knows which member it runs on.
        public let local: Bool

        public init(rank: Int, label: String, firstLayer: Int, endLayer: Int, holdsEveryEarlierLayer: Bool,
                    weightsBytes: Int, physicalMemoryBytes: Int?, local: Bool) {
            self.rank = rank; self.label = label; self.firstLayer = firstLayer; self.endLayer = endLayer
            self.holdsEveryEarlierLayer = holdsEveryEarlierLayer; self.weightsBytes = weightsBytes
            self.physicalMemoryBytes = physicalMemoryBytes; self.local = local
        }
    }

    public let ranks: [Rank]

    public init(ranks: [Rank]) { self.ranks = ranks }

    /// Bytes of weights each contiguous range holds once loaded, in rank
    /// order. A tensor is held in whole pages, so each counts one page of
    /// rounding, as the load gate and the planner count it.
    public static func weightsBytes(layout: ClusterModelLayout, boundaries: [Int], mode: ClusterGenerationMode,
                                    pageSizeBytes: Int) -> [Int] {
        let edges = [0] + boundaries + [layout.layerCount]
        let ranges = zip(edges, edges.dropFirst()).map { layout.range($0..<$1) }
        return ranges.indices.map { index in
            let last = index == ranges.count - 1
            let loads = [ranges[index]] + (mode == .phaseSplit && last ? Array(ranges[..<index]) : [])
            return loads.reduce(0) { $0 + $1.loadedBytes + $1.tensorCount * pageSizeBytes }
        }
    }

    /// The holdings of a placement described by its members in rank order and
    /// its stage boundaries. `physicalMemoryBytes` and `localLabel` are what
    /// the caller knows; a member it knows nothing about is shown without.
    public static func describe(layout: ClusterModelLayout, labels: [String], boundaries: [Int], mode: ClusterGenerationMode,
                                pageSizeBytes: Int, physicalMemoryBytes: [String: Int] = [:],
                                localLabel: String? = nil) throws -> ClusterPlacementHoldings {
        let edges = [0] + boundaries + [layout.layerCount]
        guard labels.count == boundaries.count + 1, labels.count >= 2, pageSizeBytes > 0,
              zip(edges, edges.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw ClusterPlacementError("A placement's holdings need one label per range and boundaries in order inside the model")
        }
        let bytes = weightsBytes(layout: layout, boundaries: boundaries, mode: mode, pageSizeBytes: pageSizeBytes)
        return .init(ranks: labels.indices.map { index in
            .init(rank: index, label: labels[index], firstLayer: edges[index], endLayer: edges[index + 1],
                  holdsEveryEarlierLayer: mode == .phaseSplit && index == labels.count - 1 && index > 0,
                  weightsBytes: bytes[index], physicalMemoryBytes: physicalMemoryBytes[labels[index]],
                  local: labels[index] == localLabel)
        })
    }

    /// One line, the same words wherever it is shown.
    public var line: String {
        "While the session is up: " + ranks.map { r in
            let size = r.physicalMemoryBytes.map { " of its \(ClusterPlacementExplanation.gibText($0))" } ?? ""
            return "\(r.label)\(r.local ? " (this Mac)" : "") holds layers \(r.firstLayer) to \(r.endLayer - 1)"
                + (r.holdsEveryEarlierLayer ? " and, to decode alone, every earlier layer too" : "")
                + ": \(ClusterPlacementExplanation.gibText(r.weightsBytes)) of weights\(size)"
        }.joined(separator: "; ") + "."
    }
}

/// Where the placement tool is on an installed Mac: beside the worker it is
/// built and released with, under this name. The guided step and the status
/// view both look there and nowhere else.
public enum ClusterPlacementInstallation {
    public static let toolName = "darkbloom-cluster-plan"
}
