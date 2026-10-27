import Foundation

/// Addends for a full target with an assistant on the other Mac. It loads no
/// local assistant/embedding and changes none of the target's existing charges.
struct Gemma4MTPRemoteTargetBudget {
    struct Term: Encodable, Equatable { let name: String, logicalBytes: Int, allocationBound: Int }
    let requestSHA256: String, maximumFrontier: Int
    let terms: [Term]
    let nativeBytes: Int
    let hostBytes = 16*1_048_576 + 32_768
    let fingerprint: String
    init(requestSHA256: String, maximumFrontier: Int, bound: (Int) throws -> Int) throws {
        guard requestSHA256.utf8.count == 64,
              requestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...8319).contains(maximumFrontier) else {
            throw ProbeError("Remote target additive budget identity/frontier differs")
        }
        self.requestSHA256 = requestSHA256; self.maximumFrontier = maximumFrontier
        var terms: [Term] = []
        func add(_ name: String, _ bytes: Int) throws {
            let allocation = try bound(bytes)
            guard bytes > 0, allocation >= bytes else { throw ProbeError("Remote target allocator bound is invalid") }
            terms.append(.init(name:name,logicalBytes:bytes,allocationBound:allocation))
        }
        // Exact same two width-four output worksets as frozen local auxiliary.
        // Actual protocol k2 verifies width<=3; no authority to widen is implied.
        for slot in 0..<2 {
            for name in ["logits","float32Logits","softcapTemporary","samplingRow"] {
                try add("targetVerification\(slot):"+name,4*262_144*4)
            }
            try add("targetVerification\(slot):finiteMask",4*262_144)
            try add("targetVerification\(slot):argmax",4*4)
            try add("targetVerification\(slot):finiteScalar",1)
            for name in ["preNormHidden","capturedHidden"] { try add("targetVerification\(slot):"+name,4*2816*4) }
        }
        // One immutable authoritative capture in addition to state-plan capture
        // roots. Its transfer loan may persist on failure until original retirement.
        for component in ["keys","values"] {
            try add("snapshot:full:"+component,maximumFrontier*2*512*2)
            try add("snapshot:sliding:"+component,min(maximumFrontier,1024)*8*256*2)
        }
        let transfer = try Gemma4MTPPullTransferPlan(frontier:maximumFrontier,hiddenDType:3)
        for item in transfer.senderAdditional { try add(item.name,item.bytes) }
        self.terms = terms
        nativeBytes = try QwenLongPrefillCheckedBytes.sum(terms.map(\.allocationBound))
        fingerprint = sha256(Data((["gemma4_mtp_remote_target_resources_v1",requestSHA256,
            "maximumFrontier=\(maximumFrontier)","depth=2","buffer=5","host=\(hostBytes)"]
            + terms.map { "\($0.name):\($0.logicalBytes):\($0.allocationBound)" }).joined(separator:"\n").utf8))
    }
}
