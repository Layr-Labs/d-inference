import Foundation
import Testing

@testable import ProviderCore

@Suite("ClusterPlan")
struct ClusterPlanTests {
    private func settings(
        enabled: Bool = true,
        clusterId: String = "c1",
        nodeId: String,
        members: [(String, String)],
        backend: String = "ring"
    ) -> ClusterSettings {
        ClusterSettings(
            enabled: enabled, clusterId: clusterId, nodeId: nodeId,
            members: members.map { ClusterMemberSettings(nodeId: $0.0, address: $0.1) },
            backend: backend)
    }

    @Test func resolvesRankAndNeighbors() throws {
        let plan = try ClusterPlan.resolve(settings(
            nodeId: "mac-24",
            members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")]))
        #expect(plan.rank == 1)
        #expect(plan.worldSize == 2)
        #expect(plan.isTail)
        #expect(!plan.isHead)
        #expect(plan.prevRank == 0)
        #expect(plan.nextRank == nil)
        let (prev, next) = plan.neighborNodeIds()
        #expect(prev == "mac-32")
        #expect(next == nil)
    }

    @Test func headIsRankZero() throws {
        let plan = try ClusterPlan.resolve(settings(
            nodeId: "mac-32",
            members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")]))
        #expect(plan.rank == 0)
        #expect(plan.isHead)
        #expect(plan.prevRank == nil)
        #expect(plan.nextRank == 1)
    }

    @Test func mlxRingEnvironmentIsRankOrdered() throws {
        let plan = try ClusterPlan.resolve(settings(
            nodeId: "mac-24",
            members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")]))
        let env = plan.mlxRingEnvironment()
        #expect(env["MLX_HOSTLIST"] == "10.0.0.1,10.0.0.2")
        #expect(env["MLX_RANK"] == "1")
        #expect(env["MLX_WORLD_SIZE"] == "2")
    }

    @Test func layerPlanForwardsToPartition() throws {
        let plan = try ClusterPlan.resolve(settings(
            nodeId: "mac-32",
            members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")]))
        let intervals = try plan.layerPlan(totalLayers: 48, memoryBytesByNodeId: [
            "mac-32": 28 << 30, "mac-24": 20 << 30,
        ])
        #expect(intervals.count == 2)
        #expect(intervals.reduce(0) { $0 + $1.count } == 48)
        #expect(intervals[0].count > intervals[1].count)  // bigger node, more layers
    }

    @Test func rejectsSelfNotInMembers() throws {
        #expect(throws: ClusterPlanError.selfNotInMembers(nodeId: "ghost")) {
            _ = try ClusterPlan.resolve(settings(
                nodeId: "ghost",
                members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")]))
        }
    }

    @Test func rejectsSingleMember() throws {
        #expect(throws: ClusterPlanError.singleMember) {
            _ = try ClusterPlan.resolve(settings(
                nodeId: "mac-32", members: [("mac-32", "10.0.0.1")]))
        }
    }

    @Test func rejectsDuplicateNodeId() throws {
        #expect(throws: ClusterPlanError.duplicateNodeId("dup")) {
            _ = try ClusterPlan.resolve(settings(
                nodeId: "dup",
                members: [("dup", "10.0.0.1"), ("dup", "10.0.0.2")]))
        }
    }

    @Test func rejectsUnsupportedBackend() throws {
        #expect(throws: ClusterPlanError.unsupportedBackend("infiniband")) {
            _ = try ClusterPlan.resolve(settings(
                nodeId: "mac-32",
                members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")],
                backend: "infiniband"))
        }
    }

    @Test func disabledThrows() throws {
        #expect(throws: ClusterPlanError.disabled) {
            _ = try ClusterPlan.resolve(settings(
                enabled: false, nodeId: "mac-32",
                members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")]))
        }
    }

    @Test func configRoundTripsClusterSection() throws {
        // The [cluster] section must survive JSON encode/decode (config I/O).
        let cfg = ProviderConfig(
            provider: ProviderSettings(name: "n"),
            cluster: settings(nodeId: "mac-32",
                              members: [("mac-32", "10.0.0.1"), ("mac-24", "10.0.0.2")]))
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(back.cluster?.enabled == true)
        #expect(back.cluster?.clusterId == "c1")
        #expect(back.cluster?.members.count == 2)
        #expect(back.cluster?.members[1].address == "10.0.0.2")
    }
}
