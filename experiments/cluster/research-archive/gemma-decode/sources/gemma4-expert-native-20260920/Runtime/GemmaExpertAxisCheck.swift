import Darwin
import Foundation
import MLX

@_spi(ClusterTesting) public enum GemmaExpertAxisCheck {
    public static func run(arguments: [String]) throws -> Data {
        let checkpointMode = arguments.count == 4 && arguments[0] == "--checkpoint" && arguments[2] == "--layer"
        guard arguments == ["--synthetic-small"] || arguments == ["--synthetic-gemma"] || checkpointMode else {
            throw ProbeError("Use --synthetic-small, --synthetic-gemma, or --checkpoint ABSOLUTE_MODEL --layer0..29")
        }
        let layer = checkpointMode ? Int(arguments[3]) : nil
        if checkpointMode {
            let path = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            guard arguments[1].hasPrefix("/"), path.path == arguments[1],
                  path.resolvingSymlinksInPath().path == path.path,
                  layer.map({ (0..<30).contains($0) }) == true else {
                throw ProbeError("Checkpoint mode requires a canonical absolute model path and layer0..<30")
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000_000
        _ = MLXArray(0)
        return try MLX.withError { native in
            do {
                var lifetimes: [WeakExpertAxisBank] = []
                let data: Data = try autoreleasepool {
                    var results: [ExpertAxisCaseResult] = []
                    var resources: [[String: Int]] = []
                    var layouts: [[[Int]]] = []
                    let small = arguments == ["--synthetic-small"]
                    let dtypes: [DType] = small ? [.float32, .bfloat16] : [.bfloat16]
                    let geometry = try ExpertAxisGeometry(hidden: small ? 128 : 2816,
                        intermediate: 704, experts: small ? 16 : 128, metadataDType: .bfloat16)
                    let e = geometry.experts, cut = small ? 6 : 48
                    let maps = [[Array(0..<cut), Array(cut..<e)],
                        [(0..<e).filter { $0 % 3 == 0 }, (0..<e).filter { $0 % 3 != 0 }]]
                    let checkpoint: ExpertAxisCheckpoint?
                    if checkpointMode {
                        let initial = try ExpertIDOwnership(expertCount: e, globalIDsByRank: maps[0])
                        let gate = try ExpertAxisCheckResources(geometry: geometry, ownership: initial, deadline: deadline)
                        checkpoint = try ExpertAxisCheckpoint(directory: URL(fileURLWithPath: arguments[1]), layer: layer!,
                            check: { try gate.check(native: { try native.check() }) })
                    } else { checkpoint = nil }
                    for dtype in dtypes {
                        let g = try ExpertAxisGeometry(hidden: geometry.hidden, intermediate: geometry.intermediate,
                            experts: e, metadataDType: dtype)
                        for (index, ids) in maps.enumerated() {
                            try autoreleasepool {
                                let ownership = try ExpertIDOwnership(expertCount: e, globalIDsByRank: ids)
                                let gate = try ExpertAxisCheckResources(geometry: g, ownership: ownership, deadline: deadline)
                                func check() throws { try gate.check(native: { try native.check() }) }
                                try check()
                                let synthetic = ExpertAxisSyntheticSource(geometry: g)
                                let router = try checkpoint?.router(check: check)
                                let label = "\(checkpointMode ? "checkpoint-layer-\(layer!)" : "synthetic")/\(dtype)/ownership-\(index)"
                                let values = try ExpertAxisCheckCases.run(label: label, geometry: g, ownership: ownership,
                                    read: { name, selection in
                                        try check()
                                        let array: MLXArray
                                        if let checkpoint { array = try checkpoint.readExpert(name, selection: selection) }
                                        else { array = try synthetic.read(name, selection: selection) }
                                        try check(); return array
                                    }, router: router, lifetimes: &lifetimes, check: check)
                                results += values; layouts.append(ids)
                                try checkpoint?.unchanged(); try check()
                                resources.append(["nativeReserveBytes": gate.reservedNativeBytes,
                                    "hostReserveBytes": gate.hostReserveBytes, "observations": gate.observations,
                                    "minimumActualFreeBytes": gate.minimumFreeBytes,
                                    "maximumObservedActiveBytes": gate.maximumActiveBytes])
                            }
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try native.check()
                            Memory.clearCache(); try native.check()
                        }
                    }
                    try checkpoint?.unchanged()
                    let encoded = try JSONEncoder().encode(results)
                    let cases = try JSONSerialization.jsonObject(with: encoded)
                    let result: [String: Any] = ["schema": "gemma_expert_axis_native_check_v1",
                        "passed": results.allSatisfy(\.passed), "caseCount": results.count, "cases": cases,
                        "mode": arguments[0], "globalLayerIndex": layer.map { $0 as Any } ?? NSNull(),
                        "expertOwnershipMaps": layouts, "hiddenSize": geometry.hidden,
                        "expertIntermediateSize": geometry.intermediate, "globalExpertCount": e,
                        "resources": resources, "actualQuantizedTensorsExecuted": true,
                        "invalidNativeContractsRefusedPerOwnership": 5,
                        "checkpointPayloadVerified": checkpoint != nil,
                        "artifactAggregateSHA256": checkpoint.map { $0.checkpoint.aggregate as Any } ?? NSNull(),
                        "checkpointUnchanged": checkpoint != nil,
                        "weightedReduction": "unchanged-weightedExpertSum-in-original-topK-slot-order",
                        "acceptance": "exact-output-bytes; no numerical tolerance widening",
                        "authoritativeAssignmentPacketPreparedOnCPU": true,
                        "routerReplayReadbackOnlyInCheckpointFixture": checkpointMode,
                        "deviceOnlyDynamicRoutingQualified": false, "fullDecoderExecuted": false,
                        "distributedExecution": false, "runtimeServingEnabled": false,
                        "throughputMeasurementValid": false, "wholeProcessMemoryBoundEstablished": false,
                        "physicalProcessOrLeaseRetirementEstablished": false]
                    return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try native.check()
                guard lifetimes.allSatisfy({ $0.value == nil }) else { throw ProbeError("Expert bank escaped qualification scope") }
                Memory.clearCache(); try native.check()
                guard Memory.cacheMemory == 0 else { throw ProbeError("Expert cache did not retire") }
                _ = try QwenDenseStageLoadResources.requireInitial()
                guard DispatchTime.now().uptimeNanoseconds < deadline, data.count <= 1_048_576 else {
                    throw ProbeError("Expert check final deadline/output bound exceeded")
                }
                guard var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ProbeError("Expert report shape differs")
                }
                result["expertBanksReleased"] = true; result["nativeCacheBytesAfterRelease"] = Memory.cacheMemory
                return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
            } catch {
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache()
                try native.check(); throw error
            }
        }
    }
}
