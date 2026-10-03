import Testing

@testable import DarkbloomHardwareLoad

struct CPUTopologyResolverTests {
    private func nodes(_ spans: [(type: String, cluster: Int, count: Int)]) -> [DeviceTreeCPU] {
        var result: [DeviceTreeCPU] = []
        for span in spans {
            for _ in 0..<span.count {
                result.append(
                    DeviceTreeCPU(id: result.count, cluster: span.cluster, clusterType: span.type))
            }
        }
        return result
    }

    private func layout(_ cpu: HardwareTopology.CPU) -> [String] {
        cpu.clusters.map { "\($0.id):\($0.kind.rawValue):\($0.cpus.first!)-\($0.cpus.last!)" }
    }

    @Test func m1MaxEfficiencyClusterComesFirst() {
        let cpu = CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "Performance", logicalCPUs: 8, cpusPerL2: 4),
                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 2, cpusPerL2: 2),
            ],
            nodes: nodes([("E", 0, 2), ("P", 1, 4), ("P", 2, 4)]))
        #expect(layout(cpu) == ["0:efficiency:0-1", "1:performance:2-5", "2:performance:6-9"])
        #expect(cpu.tiers.map(\.kind) == [.performance, .efficiency])
        #expect(cpu.tiers.map(\.cores) == [8, 2])
    }

    @Test func m4MaxMatchesTheLiveDeviceTree() {
        let cpu = CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "Performance", logicalCPUs: 12, cpusPerL2: 6),
                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 4, cpusPerL2: 4),
            ],
            nodes: nodes([("E", 0, 4), ("P", 1, 6), ("P", 2, 6)]))
        #expect(layout(cpu) == ["0:efficiency:0-3", "1:performance:4-9", "2:performance:10-15"])
    }

    @Test func m5MaxMapsPLettersToSuperAndMToPerformance() {
        let cpu = CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "Super", logicalCPUs: 6, cpusPerL2: 6),
                PerfLevel(index: 1, name: "Performance", logicalCPUs: 12, cpusPerL2: 6),
            ],
            nodes: nodes([("M", 0, 6), ("M", 1, 6), ("P", 2, 6)]))
        #expect(layout(cpu) == ["0:performance:0-5", "1:performance:6-11", "2:super:12-17"])
        #expect(cpu.tiers.map(\.kind) == [.super, .performance])
    }

    @Test func m3UltraKeepsBothDiesClusters() {
        let die: [(type: String, cluster: Int, count: Int)] = [("E", 0, 4), ("P", 1, 6), ("P", 2, 6)]
        let cpu = CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "Performance", logicalCPUs: 24, cpusPerL2: 6),
                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 8, cpusPerL2: 4),
            ],
            nodes: nodes(die + die.map { (type: $0.type, cluster: $0.cluster + 3, count: $0.count) }))
        #expect(cpu.clusters.count == 6)
        #expect(cpu.clusters.filter { $0.kind == .efficiency }.map(\.cpus) == [
            Array(0...3), Array(16...19),
        ])
        #expect(cpu.clusters.flatMap(\.cpus).sorted() == Array(0..<32))
    }

    @Test func missingDeviceTreeEnumeratesSlowestTierFirst() {
        let cpu = CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "Performance", logicalCPUs: 12, cpusPerL2: 6),
                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 4, cpusPerL2: 4),
            ],
            nodes: [])
        #expect(layout(cpu) == ["0:efficiency:0-3", "1:performance:4-9", "2:performance:10-15"])
    }

    @Test func inconsistentDeviceTreeFallsBackToEnumeration() {
        let cpu = CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "Performance", logicalCPUs: 8, cpusPerL2: 4),
                PerfLevel(index: 1, name: "Efficiency", logicalCPUs: 2, cpusPerL2: 2),
            ],
            nodes: nodes([("E", 0, 4), ("P", 1, 6)]))
        #expect(layout(cpu) == ["0:efficiency:0-1", "1:performance:2-5", "2:performance:6-9"])
    }

    @Test func unnamedTiersFallBackToPosition() {
        let cpu = CPUTopologyResolver.resolve(
            levels: [
                PerfLevel(index: 0, name: "", logicalCPUs: 4, cpusPerL2: 4),
                PerfLevel(index: 1, name: "", logicalCPUs: 4, cpusPerL2: 4),
            ],
            nodes: [])
        #expect(cpu.tiers.map(\.kind) == [.performance, .efficiency])
    }
}
