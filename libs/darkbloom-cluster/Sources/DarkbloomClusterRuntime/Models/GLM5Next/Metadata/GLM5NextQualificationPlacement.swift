import Foundation
import MLXLLM

/// Pure private qualification quotes. Every structural cut is considered; no
/// public catalog/admitted-cut list is changed. The caller supplies verified
/// inventory, authenticated evidence and current device bounds. These snapshots
/// do not replace LOAD/reserve/start live gates or establish RDMA readiness.
enum GLM5NextQualificationPlacement {
    struct DeviceBounds {
        let rank: Int
        let executionEnvironmentSHA256: String
        let capacityLimitBytes: Int
        /// Unified memory available AFTER baseline use and required OS headroom.
        /// Native and host additions share this ceiling and are charged together.
        let availableMemoryBytes: Int
        /// Allocator limit less active/cache bytes and required allocator headroom.
        let allocatorAvailableBytes: Int
        let maximumBufferBytes: Int
        let metadataAllowanceBytes: Int
    }
    struct RankQuote {
        let rank: Int
        let load: GLM5NextStageLoadResources.Summary
        let request: GLM5NextRequestStateBudget
        let nativePeakBytes: Int
        let hostPeakBytes: Int
        let combinedPeakBytes: Int
    }
    struct Candidate {
        let cut: Int
        let ranks: [RankQuote]
    }
    struct Refusal {
        let cut: Int
        let rank: Int
        let reason: String
    }
    struct Report {
        let structuralCuts: [Int]
        let candidates: [Candidate]
        let refusals: [Refusal]
    }

    /// Keeps every feasible cut in structural order. Selecting for throughput
    /// requires separately measured device/link costs, never a chip/model cap.
    static func evaluate(inventory: GLM5NextWeightInventory,
                         scope: GLM5NextRequestStateBudget.Scope,
                         executionPolicy: GLM5NextExecutionPolicy,
                         devices: [DeviceBounds],
                         workspace: (Int, Range<Int>) throws -> GLM5NextRequestStateBudget.WorkspaceEvidence?,
                         transport: GLM5NextRequestStateBudget.TransportTerms?,
                         allocationBound: (Int, Int) throws -> Int,
                         hostAllocationBound: (Int, Int) throws -> Int) throws -> Report {
        guard devices.count == 2, Set(devices.map(\.rank)) == Set([0, 1]) else {
            throw ProbeError("GLM placement requires both ranks")
        }
        return try evaluateRanks(inventory: inventory, scope: scope, executionPolicy: executionPolicy,
            devices: devices, workspace: workspace, transport: transport,
            allocationBound: allocationBound, hostAllocationBound: hostAllocationBound)
    }

    /// A local metadata scan never guesses the other rank's allocator bounds.
    static func evaluateLocal(inventory: GLM5NextWeightInventory,
                              scope: GLM5NextRequestStateBudget.Scope,
                              executionPolicy: GLM5NextExecutionPolicy, device: DeviceBounds,
                              workspace: (Int, Range<Int>) throws -> GLM5NextRequestStateBudget.WorkspaceEvidence?,
                              transport: GLM5NextRequestStateBudget.TransportTerms?,
                              allocationBound: (Int, Int) throws -> Int,
                              hostAllocationBound: (Int, Int) throws -> Int) throws -> Report {
        try evaluateRanks(inventory: inventory, scope: scope, executionPolicy: executionPolicy,
            devices: [device], workspace: workspace, transport: transport,
            allocationBound: allocationBound, hostAllocationBound: hostAllocationBound)
    }

    private static func evaluateRanks(inventory: GLM5NextWeightInventory,
                         scope: GLM5NextRequestStateBudget.Scope,
                         executionPolicy: GLM5NextExecutionPolicy, devices: [DeviceBounds],
                         workspace: (Int, Range<Int>) throws -> GLM5NextRequestStateBudget.WorkspaceEvidence?,
                         transport: GLM5NextRequestStateBudget.TransportTerms?,
                         allocationBound: (Int, Int) throws -> Int,
                         hostAllocationBound: (Int, Int) throws -> Int) throws -> Report {
        try scope.validate(configuration: inventory.configuration.textConfig)
        guard !devices.isEmpty, devices.count <= 2, Set(devices.map(\.rank)).count == devices.count,
              devices.allSatisfy({ (0...1).contains($0.rank) }),
              devices.allSatisfy({
                  qwenStageWireIsSHA256($0.executionEnvironmentSHA256)
                      && $0.capacityLimitBytes > 0 && $0.availableMemoryBytes >= 0
                      && $0.allocatorAvailableBytes >= 0 && $0.maximumBufferBytes > 0
                      && $0.metadataAllowanceBytes == GLM5NextResidentResourceEnvelope.metadataAllowanceBytes
              }) else { throw ProbeError("GLM placement requires two explicit bounded rank devices") }
        let layout = try GLM5NextStageLayout(inventory: inventory)
        let devices = devices.sorted { $0.rank < $1.rank }
        var candidates: [Candidate] = [], refusals: [Refusal] = []
        for cut in layout.structuralCuts {
            let split = try layout.split(at: cut, includeMTP: false)
            var ranks: [RankQuote] = []
            for device in devices {
                do {
                    let rank = device.rank
                    let request = try GLM5NextRequestStateBudget.estimate(inventory: inventory,
                        layers: split.stages[rank].globalLayers, rank: rank, scope: scope,
                        executionPolicy: executionPolicy,
                        executionEnvironmentSHA256: device.executionEnvironmentSHA256,
                        workspace: workspace(rank, split.stages[rank].globalLayers), transport: transport,
                        maximumBufferBytes: device.maximumBufferBytes,
                        allocationBound: { try allocationBound(rank, $0) },
                        hostAllocationBound: { try hostAllocationBound(rank, $0) })
                    let load = try GLM5NextStageLoadResources(inventory: inventory,
                        stageIndex: rank, cut: cut, includeMTP: false, executionPolicy: executionPolicy,
                        metadataAllowanceBytes: device.metadataAllowanceBytes,
                        maximumBufferBytes: device.maximumBufferBytes,
                        allocationBound: { try allocationBound(rank, $0) }).summary
                    // Deliberately overlap full construction and request charges,
                    // matching the resident LOAD gate's up-front reservation.
                    let peak = try GLM5NextResidentPeak(load: load, request: request)
                    let native = peak.nativeBytes, host = peak.hostBytes, combined = peak.reservedBytes
                    guard combined <= device.capacityLimitBytes else {
                        throw ProbeError("GLM cut exceeds rank capacity reservation")
                    }
                    guard combined <= device.availableMemoryBytes else {
                        throw ProbeError("GLM cut exceeds available unified memory after headroom")
                    }
                    guard native <= device.allocatorAvailableBytes else {
                        throw ProbeError("GLM cut exceeds available native allocator capacity")
                    }
                    ranks.append(.init(rank: rank, load: load, request: request,
                        nativePeakBytes: native, hostPeakBytes: host, combinedPeakBytes: combined))
                } catch {
                    refusals.append(.init(cut: cut, rank: device.rank, reason: String(describing: error)))
                }
            }
            if ranks.count == devices.count { candidates.append(.init(cut: cut, ranks: ranks)) }
        }
        return .init(structuralCuts: layout.structuralCuts, candidates: candidates, refusals: refusals)
    }
}
