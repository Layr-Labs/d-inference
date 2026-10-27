import Foundation
import MLX

struct ExpertAxisRDMAExecution: Encodable {
    let schema = "gemma4_expert_rdma_result_v1"
    let job: ExpertAxisRDMAJob
    let scopeSHA256: String
    let artifactAggregateSHA256 = Gemma4ArtifactMetadata.artifactAggregateSHA256
    let globalExpertIDsByRank: [[Int]], loadedLocalExpertBytes: Int, loadedReferenceExpertBytes: Int
    let cases: [ExpertAxisRDMACaseObservation]
    let sentControlBytes: Int, receivedControlBytes: Int, sentTensorBytes: Int, receivedTensorBytes: Int
    let minimumActualFreeBytes: Int, maximumObservedActiveBytes: Int, resourceObservations: Int
    let reservedNativeBytes: Int, hostReserveBytes: Int
    let expertBanksReleased = true, checkpointUnchanged = true, actualQuantizedTensorsExecuted = true
    let distributedExecution = true, authoritativeCPUFixtureRouteReadback = true
    let fullDecoderExecuted = false, deviceOnlyDynamicRoutingQualified = false, encryptedRDMA = false
    let runtimeServingEnabled = false, throughputMeasurementValid = false, wholeProcessMemoryBoundEstablished = false
    let physicalProcessOrLeaseRetirementEstablished = false
    var passed: Bool { cases.count == job.tokenCounts.count && cases.allSatisfy(\.acceptedByReferenceRank) }
}

enum ExpertAxisRDMARuntime {
    static func run(job: ExpertAxisRDMAJob, group: Collective, resources: ExpertAxisRDMAResources,
                    check: () throws -> Void) throws -> Data {
        let wire = try ExpertAxisRDMAWire(job: job, group: group)
        try wire.checkpoint("begin", check: check)
        let ownership = try job.expertOwnership()
        var lifetimes: [WeakExpertAxisBank] = []
        let execution: ([ExpertAxisRDMACaseObservation], Int, Int) = try autoreleasepool {
            let checkpoint = try ExpertAxisCheckpoint(directory: URL(fileURLWithPath: job.modelDirectory), layer: job.layer, check: check)
            func read(_ name: String, _ selection: TensorSelection) throws -> MLXArray {
                try check(); let value = try checkpoint.readExpert(name, selection: selection); try check(); return value
            }
            let local = try ExpertAxisBank(geometry: checkpoint.geometry, globalExpertIDs: ownership.globalIDsByRank[job.rank],
                read: read, check: check)
            lifetimes.append(.init(local))
            let reference: ExpertAxisBank?
            let router: ExpertAxisRouterReplay?
            if job.rank == 0 {
                reference = try ExpertAxisBank(geometry: checkpoint.geometry, globalExpertIDs: Array(0..<128), read: read, check: check)
                lifetimes.append(.init(reference!)); router = try checkpoint.router(check: check)
            } else { reference = nil; router = nil }
            try checkpoint.unchanged(); try check()
            try wire.checkpoint("banks-loaded", check: check)
            var cases: [ExpertAxisRDMACaseObservation] = []
            for index in job.tokenCounts.indices {
                let value = try autoreleasepool {
                    try ExpertAxisRDMACase.run(job: job, index: index, ownership: ownership, localBank: local,
                        reference: reference, router: router, wire: wire, check: check)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
                cases.append(value)
            }
            try checkpoint.unchanged(); try check()
            return (cases, local.loadedBytes, reference?.loadedBytes ?? 0)
        }
        Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
        guard lifetimes.allSatisfy({ $0.value == nil }) else { throw ProbeError("Expert RDMA bank escaped original qualification scope") }
        Memory.clearCache(); try check()
        try wire.checkpoint("banks-released", check: check)
        let report = ExpertAxisRDMAExecution(job: job, scopeSHA256: job.scopeSHA256,
            globalExpertIDsByRank: ownership.globalIDsByRank, loadedLocalExpertBytes: execution.1,
            loadedReferenceExpertBytes: execution.2, cases: execution.0,
            sentControlBytes: wire.sentControlBytes, receivedControlBytes: wire.receivedControlBytes,
            sentTensorBytes: wire.sentTensorBytes, receivedTensorBytes: wire.receivedTensorBytes,
            minimumActualFreeBytes: resources.base.minimumFreeBytes, maximumObservedActiveBytes: resources.base.maximumActiveBytes,
            resourceObservations: resources.base.observations,
            reservedNativeBytes: resources.base.reservedNativeBytes + ExpertAxisRDMAResources.extraNativeBytes,
            hostReserveBytes: resources.base.hostReserveBytes + ExpertAxisRDMAResources.extraHostBytes)
        var object = try JSONSerialization.jsonObject(with: canonicalJSONData(report)) as! [String: Any]
        object["passed"] = report.passed
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
