import Foundation
import MLX
import MLXLMCommon

enum ExpertAxisCheckCases {
    static func input(rows: Int, hidden: Int, dtype: DType) -> MLXArray {
        let values: [Float] = (0..<(rows * hidden)).map { index in
            Float((index * 37 + index / hidden * 11) % 127 - 63) / 128
        }
        return MLXArray(values).reshaped(rows, hidden).asType(dtype)
    }

    static func run(label: String, geometry: ExpertAxisGeometry, ownership: ExpertIDOwnership,
                    read: (String, TensorSelection) throws -> MLXArray,
                    router: ExpertAxisRouterReplay?, lifetimes: inout [WeakExpertAxisBank],
                    check: () throws -> Void) throws -> [ExpertAxisCaseResult] {
        let reference = try ExpertAxisBank(geometry: geometry, globalExpertIDs: Array(0..<geometry.experts), read: read, check: check)
        let banks = try ownership.globalIDsByRank.map {
            try ExpertAxisBank(geometry: geometry, globalExpertIDs: $0, read: read, check: check)
        }
        lifetimes += ([reference] + banks).map(WeakExpertAxisBank.init)
        guard banks.reduce(0, { $0 + $1.loadedBytes }) == reference.loadedBytes else {
            throw ProbeError("Expert-axis selected banks do not conserve source payload bytes")
        }
        try negativeControls(geometry: geometry, ownership: ownership, banks: banks, check: check)
        var results: [ExpertAxisCaseResult] = []
        for rows in ExpertAxisQualificationLimits.cases(experts: geometry.experts) {
            if let router {
                let result = try autoreleasepool {
                    let residual = input(rows: rows, hidden: geometry.hidden, dtype: .bfloat16)
                    let route = router.route(residual)
                    eval(route.input, route.ids, route.weights); try check()
                    // Qualification boundary only. No claim of device-only
                    // variable-length routing or an integrated generation loop.
                    let ids = route.ids.asArray(UInt32.self); try check()
                    let selected = (0..<rows).map { row in (0..<8).map { Int(ids[row * 8 + $0]) } }
                    return try one(label: label + "/actual-router-replay", ownership: ownership,
                        reference: reference, banks: banks, input: route.input, selected: selected,
                        weights: route.weights, router: router, check: check)
                }
                results.append(result)
            } else {
                for pattern in ["balanced", "all-rank0", "all-rank1"] {
                    let result = try autoreleasepool {
                        let forcedRank: Int? = pattern == "balanced" ? nil : (pattern == "all-rank0" ? 0 : 1)
                        let topK = forcedRank.map { min(8, ownership.globalIDsByRank[$0].count) } ?? 8
                        let selected = (0..<rows).map { row in
                            (0..<topK).map { slot in
                                if let rank = forcedRank {
                                    let ids = ownership.globalIDsByRank[rank]
                                    return ids[(row * 3 + slot) % ids.count]
                                }
                                return (row * 7 + slot * 3) % geometry.experts
                            }
                        }
                        let dtype: DType = geometry.metadataDType == .float32 ? .float32 : .bfloat16
                        var weightValues: [Float] = []
                        weightValues.reserveCapacity(rows * topK)
                        let denominator = Float(topK * (topK + 1))
                        for row in 0..<rows {
                            let rowScale: Float = 1 + Float(row % 3) / 4
                            for slot in 0..<topK {
                                weightValues.append(Float(slot + 1) / denominator * rowScale)
                            }
                        }
                        let weights = MLXArray(weightValues).reshaped(rows, topK).asType(dtype)
                        return try one(label: label + "/" + pattern, ownership: ownership,
                            reference: reference, banks: banks, input: input(rows: rows, hidden: geometry.hidden, dtype: dtype),
                            selected: selected, weights: weights, router: nil, check: check)
                    }
                    results.append(result)
                }
            }
        }
        return results
    }

    private static func negativeControls(geometry: ExpertAxisGeometry, ownership: ExpertIDOwnership,
                                         banks: [ExpertAxisBank], check: () throws -> Void) throws {
        func refuse(_ expected: String, _ body: () throws -> Void) throws {
            do { try body() }
            catch {
                try check()
                guard String(describing: error) == expected else { throw error }
                return
            }
            throw ProbeError("Invalid native expert contract was accepted")
        }
        var readerCalled = false
        try refuse("Expert-axis bank IDs must be increasing, unique and in range") {
            _ = try ExpertAxisBank(geometry: geometry, globalExpertIDs: [0, 0], read: { _, _ in
                readerCalled = true; return MLXArray.zeros([1])
            }, check: check)
        }
        guard !readerCalled else { throw ProbeError("Invalid bank ownership reached its tensor reader") }
        try refuse("Selected expert tensor shape/dtype differs: down_proj.biases") {
            _ = try ExpertAxisBank(geometry: geometry, globalExpertIDs: [0],
                read: { _, _ in MLXArray.zeros([1], dtype: .uint32) }, check: check)
        }
        try refuse("invalidRoutes") {
            _ = try ExpertAxisPreparedDispatch(ownership: ownership, selectedGlobalIDs: [[0, 0]], check: check)
        }
        let packet = try ExpertAxisPreparedDispatch(ownership: ownership, selectedGlobalIDs: [[0]], check: check)
        let x = MLXArray.zeros([1, geometry.hidden], dtype: .bfloat16)
        try refuse("Expert-axis dispatch differs from its owned banks") { _ = try packet.unweighted(x, banks: Array(banks.reversed())) }
        try refuse("Expert-axis weighted reduction geometry/dtype differs") { _ = try packet.weighted(MLXArray.zeros([1, 1, geometry.hidden], dtype: .bfloat16),
            weights: MLXArray.ones([1, 1], dtype: .float32)) }
        try check()
    }

    private static func one(label: String, ownership: ExpertIDOwnership,
        reference: ExpertAxisBank, banks: [ExpertAxisBank], input: MLXArray,
        selected: [[Int]], weights: MLXArray, router: ExpertAxisRouterReplay?,
        check: () throws -> Void) throws -> ExpertAxisCaseResult {
        let dispatch = try ExpertAxisPreparedDispatch(ownership: ownership, selectedGlobalIDs: selected, check: check)
        eval(input, weights); try check()
        let before = weights.asData(access: .copy).data; try check()
        let expectedOutputs = reference.module(input, dispatch.globalIDs)
        let actualOutputs = try dispatch.unweighted(input, banks: banks)
        let outputs = try compareExpertAxis(expectedOutputs, actualOutputs, check: check)
        let expected = weightedExpertSum(expectedOutputs, weights)
        let actual = try dispatch.weighted(actualOutputs, weights: weights)
        let combined = try compareExpertAxis(expected, actual, check: check)
        let normalized: ExpertAxisDifference?
        if let router { normalized = try compareExpertAxis(router.postNorm(expected), router.postNorm(actual), check: check) }
        else { normalized = nil }
        let after = weights.asData(access: .copy).data; try check()
        guard before == after else { throw ProbeError("Expert-axis routing weights changed") }
        return .init(label: label, inputDType: String(describing: input.dtype),
            tokenCount: dispatch.plan.tokenCount, topK: dispatch.plan.topK,
            assignmentCounts: dispatch.plan.assignmentCountsByRank, selectedGlobalIDs: selected,
            projectionPolicies: dispatch.projectionPolicies,
            routingWeightsSHA256: sha256(before), expertOutputs: outputs, weighted: combined, postNorm: normalized)
    }
}

final class WeakExpertAxisBank {
    weak var value: ExpertAxisBank?
    init(_ value: ExpertAxisBank) { self.value = value }
}
