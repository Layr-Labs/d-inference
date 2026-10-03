import Foundation

/// One `hw.perflevelN` tier. Apple orders tiers fastest-first.
public struct PerfLevel: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let logicalCPUs: Int
    public let cpusPerL2: Int

    public init(index: Int, name: String, logicalCPUs: Int, cpusPerL2: Int) {
        self.index = index
        self.name = name
        self.logicalCPUs = logicalCPUs
        self.cpusPerL2 = cpusPerL2
    }
}

/// One `IODeviceTree:/cpus/cpuN` node.
public struct DeviceTreeCPU: Sendable, Equatable {
    public let id: Int
    public let cluster: Int
    /// `cluster-type` letter: "E", "M" or "P".
    public let clusterType: String

    public init(id: Int, cluster: Int, clusterType: String) {
        self.id = id
        self.cluster = cluster
        self.clusterType = clusterType
    }
}

/// Maps logical CPUs to tiers and clusters.
///
/// `hw.perflevel*` gives tier sizes but not which CPU indices belong to which
/// tier, so membership comes from the device tree. Its cluster-type letters
/// rank E < M < P (on M5 "P" is the Super tier and "M" the Performance tier),
/// which lines up with perf levels ordered fastest-first.
enum CPUTopologyResolver {
    private struct Assignment {
        let cpu: Int
        let cluster: Int
        let level: Int
    }

    static func resolve(levels: [PerfLevel], nodes: [DeviceTreeCPU]) -> HardwareTopology.CPU {
        let tiers = levels.map { level in
            HardwareTopology.CPUTier(
                level: level.index, name: level.name,
                kind: kind(of: level, isSlowest: level.index == levels.count - 1 && levels.count > 1),
                cores: level.logicalCPUs)
        }
        let kinds = Dictionary(tiers.map { ($0.level, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let assignments = deviceTreeAssignments(levels: levels, nodes: nodes)
            ?? enumeratedAssignments(levels: levels)
        let clusters = Dictionary(grouping: assignments, by: \.cluster)
            .sorted { $0.key < $1.key }
            .map { id, members in
                HardwareTopology.CPUCluster(
                    id: id, kind: kinds[members[0].level] ?? .performance,
                    cpus: members.map(\.cpu).sorted())
            }
        return HardwareTopology.CPU(tiers: tiers, clusters: clusters)
    }

    private static func kind(of level: PerfLevel, isSlowest: Bool) -> CoreKind {
        switch level.name.lowercased() {
        case "super": return .super
        case "performance": return .performance
        case "efficiency": return .efficiency
        default: return isSlowest ? .efficiency : .performance
        }
    }

    private static func deviceTreeAssignments(
        levels: [PerfLevel], nodes: [DeviceTreeCPU]
    ) -> [Assignment]? {
        let letters = Set(nodes.map(\.clusterType)).sorted { rank($0) > rank($1) }
        guard !nodes.isEmpty, letters.count == levels.count, !letters.contains(where: { rank($0) < 0 }),
            Set(nodes.map(\.id)) == Set(0..<nodes.count),
            zip(letters, levels).allSatisfy({ letter, level in
                nodes.filter { $0.clusterType == letter }.count == level.logicalCPUs
            }),
            Dictionary(grouping: nodes, by: \.cluster).values.allSatisfy({
                Set($0.map(\.clusterType)).count == 1
            })
        else { return nil }
        let levelByLetter = Dictionary(uniqueKeysWithValues: zip(letters, levels.map(\.index)))
        return nodes.map { node in
            Assignment(cpu: node.id, cluster: node.cluster, level: levelByLetter[node.clusterType]!)
        }
    }

    /// Without a usable device tree, assume the slowest tier is enumerated
    /// first (true on M1–M4) and derive clusters from `cpusperl2`.
    private static func enumeratedAssignments(levels: [PerfLevel]) -> [Assignment] {
        var assignments: [Assignment] = []
        var cluster = 0
        for level in levels.reversed() where level.logicalCPUs > 0 {
            let perCluster = max(level.cpusPerL2, 1)
            for offset in 0..<level.logicalCPUs {
                assignments.append(
                    Assignment(
                        cpu: assignments.count, cluster: cluster + offset / perCluster,
                        level: level.index))
            }
            cluster += (level.logicalCPUs + perCluster - 1) / perCluster
        }
        return assignments
    }

    private static func rank(_ letter: String) -> Int {
        switch letter {
        case "E": return 0
        case "M": return 1
        case "P": return 2
        default: return -1
        }
    }
}
