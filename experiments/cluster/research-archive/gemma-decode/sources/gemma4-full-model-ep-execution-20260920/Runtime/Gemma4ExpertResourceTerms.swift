import Foundation

/// Additions to the existing full-decoder ledger, not a new memory owner.
/// Every layer is charged concurrently even though the first path is serialized.
struct Gemma4ExpertResourceTerms: Encodable {
    static let controlBytes = 4_096
    static let maximumLayerExchanges = (2 + 3) * 30 // native probe2 + request3
    static let controlRecordLimit = 1_024
    static let expectedControlRecords = maximumLayerExchanges * 4 + 7
    static let reportEncodingHostBytes = 8 * 1_048_576
    let policy = "gemma4_full_expert_correctness_resources_v1"
    let ownershipSHA256: String
    let rank: Int
    let ownedExpertCount: Int
    let frameTokenLimit: Int
    let assignmentLimit: Int
    let payloadByteLimit: Int
    let hostBytes: Int
    let arrayTerms: [Gemma4ShortResourceBudget.ArrayTerm]
    let collectiveNativeAllowanceBytes: Int
    let collectiveHostAllowanceBytes: Int
    let measuredPeakBoundEstablished = false

    static func derive(partition: Gemma4ExpertPartition, frameTokens: Int) throws -> Self {
        guard (2...ExpertAxisQualificationLimits.maximumTokens).contains(frameTokens) else {
            throw ProbeError("Gemma expert resource frame exceeds shared qualified envelope")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        let assignments = try product([frameTokens, 8])
        guard assignments <= ExpertAxisQualificationLimits.maximumAssignments else {
            throw ProbeError("Gemma expert assignment allowance exceeds shared projection envelope")
        }
        var terms: [Gemma4ShortResourceBudget.ArrayTerm] = []
        func add(_ name: String, _ shape: [Int], bytes: Int = 4) throws {
            terms.append(.init(name: name, bytes: try product(shape + [bytes])))
        }
        for layer in 0..<30 {
            let prefix = "layer\(layer):ep:"
            // Keep every original full-bank activation term. Add the complete
            // local padded graph, even if this frame needs no padding.
            for name in ["paddedInput", "sortedInput", "paddedDown", "paddedUnsort"] {
                try add(prefix + name, [assignments, 2816])
            }
            for name in ["paddedGate", "paddedUp", "paddedActivation"] {
                try add(prefix + name, [assignments, 704])
            }
            for name in ["tokenRows", "localIDs", "order", "inverseOrder", "sortedIDs", "reassemblyOrder"] {
                try add(prefix + name, [assignments])
            }
            // Includes sender gather/compact ownership, completed receiver,
            // joined/reassembled output, and original unweighted local aliases.
            for name in ["senderGather", "senderOwned", "peerOwned", "rankMajorJoin", "slotReassembly"] {
                try add(prefix + name, [assignments, 2816])
            }
            try add(prefix + "senderCopyIndex", [assignments])
        }
        // Control buffers can overlap data buffers; no control-lifetime discount.
        for name in ["controlSend", "controlReceive", "controlSendPrefix", "controlReceivePrefix"] {
            try add("ep:" + name, [name.hasSuffix("Prefix") ? 4 : controlBytes], bytes: 1)
        }
        // Same conservative bounded transport allowance as the current C128
        // one-layer RDMA qualification, additional to all explicit MLX buffers.
        let collectiveNative = 32 * 1_048_576, collectiveHost = 32 * 1_048_576
        try add("ep:collectiveNativeAllowance", [collectiveNative], bytes: 1)
        let payload = try product([assignments, 2816, 2])
        let assignmentHost = try product([assignments,
            5 * MemoryLayout<ExpertAssignment>.stride + 6 * MemoryLayout<Int>.stride
                + 3 * MemoryLayout<UInt32>.stride])
        // CPU routes, duplicated mapping/padded arrays, original tensor readback,
        // sender+receiver hash copies, retained exchange receipts and encoding.
        let host = try sum([collectiveHost, assignmentHost,
            product([frameTokens, 2816, 2]), product([frameTokens, 8, 2]),
            product([3, payload]), product([8, controlBytes]),
            product([maximumLayerExchanges, controlBytes]), reportEncodingHostBytes])
        return .init(ownershipSHA256: sha256(try canonicalJSONData(partition.globalIDsByRank)),
            rank: partition.rank, ownedExpertCount: partition.ownedIDs.count,
            frameTokenLimit: frameTokens, assignmentLimit: assignments, payloadByteLimit: payload,
            hostBytes: host, arrayTerms: terms,
            collectiveNativeAllowanceBytes: collectiveNative, collectiveHostAllowanceBytes: collectiveHost)
    }
}
