import Foundation

/// Named auxiliary requests added to the ORIGINAL target inequalities, not a
/// replacement serving floor or a claim to bound every native kernel workspace.
struct Gemma4MTPAuxiliaryBudget {
    enum Placement: String, Encodable { case localTarget, remoteAssistant }
    struct Item: Encodable, Equatable { let source: String, name: String, shape: [Int], bytes: Int }
    struct Term: Encodable { let name: String, logicalBytes: Int, allocationBound: Int }
    let placement: Placement
    let requestSHA256: String
    let maximumFrontier: Int
    let maximumDraftTokens = 2
    let maximumBufferedProposals = 5
    let items: [Item], itemBounds: [Int]
    let constructorTerms: [Term], liveTerms: [Term]
    let constructorBytes: Int, liveNativeBytes: Int, liveHostBytes: Int
    let snapshotLogicalBytes: Int
    let fingerprint: String

    init(artifact: Gemma4AssistantArtifact, placement: Placement, requestSHA256: String,
         maximumFrontier: Int, bound: (Int) throws -> Int) throws {
        guard (1...8319).contains(maximumFrontier), requestSHA256.utf8.count == 64,
              requestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProbeError("Assistant auxiliary request envelope differs")
        }
        self.placement = placement; self.requestSHA256 = requestSHA256; self.maximumFrontier = maximumFrontier
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func term(_ name: String, _ bytes: Int) throws -> Term {
            let allocation = try bound(bytes)
            guard bytes > 0, allocation >= bytes else { throw ProbeError("Assistant native allocation bound differs") }
            return .init(name:name,logicalBytes:bytes,allocationBound:allocation)
        }
        var items = artifact.tensors.map { Item(source:"assistant",name:$0.name,shape:$0.shape,bytes:$0.bytes) }
        if placement == .remoteAssistant {
            for (name,shape,bytes) in [("biases",[262144,44],23_068_672),("scales",[262144,44],23_068_672),("weight",[262144,352],369_098_752)] {
                items.append(.init(source:"targetEmbedding",name:"language_model.model.embed_tokens."+name,shape:shape,bytes:bytes))
            }
        }
        self.items = items; itemBounds = try items.map { try term($0.name,$0.bytes).allocationBound }
        var constructor: [Term] = [], live: [Term] = []
        for tensor in artifact.tensors {
            if !tensor.name.hasSuffix(".scales") && !tensor.name.hasSuffix(".biases") {
                let expansion = tensor.sourceDType == "U32" ? 8 : 1
                constructor.append(try term("unquantized:"+tensor.name,product(tensor.shape+[4,expansion])))
            }
            // Even though the checked constructor rejects evaluated packed
            // outputs, retain both pre/post-quantization requests until ALL94
            // source replacements finish. Do not discount uninspected graphs.
            constructor.append(try term("constructorOutput:"+tensor.name,
                product(tensor.shape+[4])))
            if tensor.name.hasSuffix(".scales") || tensor.name.hasSuffix(".biases") {
                live.append(try term("parameterFloat32Cast:"+tensor.name,product(tensor.shape+[4])))
            }
        }
        constructorTerms = constructor; constructorBytes = try sum(constructor.map(\.allocationBound))
        let sliding = min(maximumFrontier,1024)
        let snapshot = try sum([product([2,maximumFrontier,2,512,2]),product([2,sliding,8,256,2])])
        snapshotLogicalBytes = snapshot
        // Exact BF16 receipt required by owner attachment. Every individual
        // K/V allocation is rounded; immutable snapshot, native receive/pack
        // and retained transfer copy are separate simultaneous buffers.
        for copy in 0..<(placement == .remoteAssistant ? 3 : 1) {
            for component in ["keys","values"] {
                live.append(try term("snapshot\(copy):full:"+component,product([maximumFrontier,2,512,2])))
                live.append(try term("snapshot\(copy):sliding:"+component,product([sliding,8,256,2])))
            }
        }
        for step in 0..<maximumBufferedProposals {
            func add(_ name: String, _ shape: [Int], bytes: Int = 4) throws {
                live.append(try term("proposal\(step):"+name,product(shape+[bytes])))
            }
            for name in ["targetEmbedding","targetEmbeddingScaled","carryHidden","nextHidden"] { try add(name,[2816]) }
            try add("embeddingGatherWeight",[2816/8]); try add("embeddingGatherScales",[2816/64]); try add("embeddingGatherBiases",[2816/64])
            try add("conditioningConcat",[2*2816]); try add("preProjection",[1024])
            for layer in 0..<4 {
                let dim = layer == 3 ? 512 : 256, length = layer == 3 ? maximumFrontier : sliding
                for name in ["input","inputNorm","outputProjection","postAttentionNorm","attentionResidual",
                             "preFeedforwardNorm","downProjection","postFeedforwardNorm","residual","layerScale"] {
                    try add("layer\(layer):"+name,[1024])
                }
                for name in ["queryProjection","queryNorm","queryRoPE","attentionOutput","attentionCast"] { try add("layer\(layer):"+name,[16,dim]) }
                for name in ["scores","probabilities"] { try add("layer\(layer):"+name,[16,length]) }
                try add("layer\(layer):mask",[length])
                for name in ["gate","up","gelu","product"] { try add("layer\(layer):"+name,[8192]) }
            }
            try add("finalNorm",[1024]); try add("headInputCast",[1024])
            try add("fullVocabularyLogits",[262144]); try add("argmaxScratch",[262144]); try add("token",[1])
        }
        if placement == .localTarget {
            // The ordinary C64 trunk already covers width<=4, but its head
            // policy names only ONE vocabulary row. Keep that original charge
            // and add two complete width-four output worksets here: current
            // rectangular verification and any retained prior output/capture.
            // This never borrows the assistant's five proposal graph slots.
            for slot in 0..<2 {
                for name in ["logits", "float32Logits", "softcapTemporary", "samplingRow"] {
                    live.append(try term("targetVerification\(slot):"+name,product([4,262144,4])))
                }
                live.append(try term("targetVerification\(slot):finiteMask",product([4,262144])))
                live.append(try term("targetVerification\(slot):argmax",product([4,4])))
                live.append(try term("targetVerification\(slot):finiteScalar",1))
                for name in ["preNormHidden", "capturedHidden"] {
                    live.append(try term("targetVerification\(slot):"+name,product([4,2816,4])))
                }
            }
        }
        live.append(try term("boundedNativeControlFrame",16384))
        liveTerms = live; liveNativeBytes = try sum(live.map(\.allocationBound))
        // Two complete host serialization/receive buffers for remote snapshot,
        // plus bounded control/frame and graph/metadata host operational reserve.
        // These are explicit allowances, NOT a Foundation malloc peak proof.
        liveHostBytes = try sum([16*1_048_576,32_768,placement == .remoteAssistant ? product([2,snapshot]) : 0])
        fingerprint = sha256(Data((["gemma4-mtp-auxiliary-v1",artifact.parameterLayoutSHA256,placement.rawValue,
            requestSHA256,"maximumFrontier=\(maximumFrontier)","depth=2","buffer=5",
            "native=\(liveNativeBytes)","host=\(liveHostBytes)","constructor=\(constructorBytes)"]
            + items.map { "\($0.source):\($0.name):\($0.bytes)" }
            + (constructor+live).map { "\($0.name):\($0.logicalBytes):\($0.allocationBound)" }).joined(separator:"\n").utf8))
    }
}
