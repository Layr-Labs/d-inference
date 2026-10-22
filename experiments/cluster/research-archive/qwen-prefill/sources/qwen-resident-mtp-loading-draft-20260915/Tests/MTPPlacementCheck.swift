import Foundation

private struct FixtureFailure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FixtureFailure(message: message) }
}

@main struct MTPPlacementCheck {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let configuration = try Data(contentsOf: directory.appendingPathComponent("configuration.json"))
        let values = try JSONDecoder().decode([QwenDenseCanonicalTensor].self,
            from: Data(contentsOf: directory.appendingPathComponent("additional-tensors.json")))
        let head = values.filter { $0.name.hasPrefix("mtp.") }
        let embedding = values.filter { !$0.name.hasPrefix("mtp.") }
        var accepted = 0, rejected = 0
        func refuses(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { rejected += 1; return }
            throw FixtureFailure(message: "Accepted invalid case: " + name)
        }
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<4, 4..<32])
        func placement(_ h: [QwenDenseCanonicalTensor], _ e: [QwenDenseCanonicalTensor]) throws -> QwenResidentMTPPlacement {
            try .derive(configuration: configuration, plan: plan, head: h, embedding: e)
        }
        let valid = try placement(head, embedding)
        try require(head.count == 31 && embedding.count == 3, "Complete additional source fixture")
        try require(valid.headBytes == 136_881_152 && valid.replicatedEmbeddingBytes == 572_129_280,
            "Independent retained payload totals")
        try require(valid.additionalTensorBytes == 709_010_432 && valid.ownerRank == 1,
            "Additional storage/final-rank ownership")
        try require(valid.embeddingSourceOwnerRank == 0 && valid.embeddingIsExplicitReplica && !valid.generationEnabled,
            "Replica scope and no generation claim")
        accepted += 1

        // Real production Plan still excludes all assistant tensors. The source
        // embedding belongs to rank 0 and remains an inert ingress on rank 1.
        for cut in [4, 8, 12, 16] {
            let p = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<32])
            let v = try QwenResidentMTPPlacement.derive(configuration: configuration, plan: p,
                head: head, embedding: embedding)
            try require(v.targetPlanSHA256 == p.fingerprint && v.additionalTensorBytes == 709_010_432,
                "Plan preserved across supported stage cuts")
            for tensor in embedding {
                try require(try p.parameter(canonicalSourceName: tensor.name)?.stage == 0, "Embedding source owner")
            }
            for tensor in head { try require(try p.parameter(canonicalSourceName: tensor.name) == nil, "MTP excluded from target Plan") }
            try require(p.stages[1].inertModules.map(\.path) == [QwenResidentMTPPlacement.embeddingRoot], "Residual ingress remains inert")
            try require(try p.parameter(canonicalSourceName: "language_model.model.norm.weight")?.stage == 1, "Final norm owner")
            try require(try p.parameter(canonicalSourceName: "language_model.lm_head.weight")?.stage == 1, "Final head owner")
            accepted += 1
        }
        let reversed = try placement(Array(head.reversed()), Array(embedding.reversed()))
        try require(reversed.tensorsInReadOrder == valid.tensorsInReadOrder, "Canonical read order")
        try QwenResidentMTPPlacement.requireOwner(rank: 1); accepted += 1
        for rank in [-1, 0, 2] { try refuses("wrong rank") { try QwenResidentMTPPlacement.requireOwner(rank: rank) } }

        try refuses("missing head") { _ = try placement(Array(head.dropLast()), embedding) }
        try refuses("duplicate head") { _ = try placement(head + [head[0]], embedding) }
        try refuses("missing embedding") { _ = try placement(head, Array(embedding.dropLast())) }
        try refuses("duplicate embedding") { _ = try placement(head, embedding + [embedding[0]]) }
        func replacing(_ tensor: QwenDenseCanonicalTensor, name: String? = nil, shape: [Int]? = nil,
                       dtype: String? = nil, bytes: Int? = nil) -> QwenDenseCanonicalTensor {
            .init(name: name ?? tensor.name, shape: shape ?? tensor.shape,
                sourceDType: dtype ?? tensor.sourceDType, byteCount: bytes ?? tensor.byteCount)
        }
        var changed = head; changed[0] = replacing(changed[0], name: "mtp.unrecognized.weight")
        try refuses("unknown head parameter") { _ = try placement(changed, embedding) }
        changed = head; let floatIndex = changed.firstIndex { $0.sourceDType == "BF16" }!
        changed[floatIndex] = replacing(changed[floatIndex], dtype: "F16")
        try refuses("same-width wrong float dtype") { _ = try placement(changed, embedding) }
        changed = head; let packedIndex = changed.firstIndex { $0.sourceDType == "U32" }!
        changed[packedIndex] = replacing(changed[packedIndex], dtype: "F32")
        try refuses("same-width unpacked weight") { _ = try placement(changed, embedding) }
        changed = head; let shapeIndex = changed.firstIndex { $0.name.hasSuffix("q_proj.weight") }!
        changed[shapeIndex] = replacing(changed[shapeIndex], shape: [4096, 1024])
        try refuses("same-bytes wrong projection geometry") { _ = try placement(changed, embedding) }
        changed = head; changed[0] = replacing(changed[0], bytes: changed[0].byteCount + 1)
        try refuses("one-byte payload mismatch") { _ = try placement(changed, embedding) }
        var replica = embedding; replica[0] = replacing(replica[0], name: "language_model.lm_head.biases")
        try refuses("head substituted for embedding") { _ = try placement(head, replica) }
        let changedConfiguration = configuration + Data([32])
        try refuses("semantically equal unpinned configuration") {
            let p = try QwenLayerStagePlan(configuration: changedConfiguration, ranges: [0..<4, 4..<32])
            _ = try QwenResidentMTPPlacement.derive(configuration: changedConfiguration, plan: p, head: head, embedding: embedding)
        }
        try refuses("active MTP Plan") { _ = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<4, 4..<32], activeMTP: true) }

        let exact = try QwenResidentMTPLoadResources(placement: valid, maximumBufferBytes: 508_559_360, bound: { $0 })
        let rounded = try QwenResidentMTPLoadResources(placement: valid, maximumBufferBytes: 1 << 30,
            bound: { (($0 + 32767) / 32768) * 32768 })
        try require(exact.reservedTensorBytes == 709_010_432 && exact.largestHostTensorBytes == 508_559_360,
            "Every extra tensor and largest staging buffer charged")
        try require(rounded.reservedTensorBytes > exact.reservedTensorBytes, "Actual rounding remains charged")
        try require(try exact.pending(after: 0).tensorBytes == 709_010_432, "Initial additional reserve")
        try require(try exact.pending(after: 34).tensorBytes == 0 && exact.pending(after: 34).hostBytes == 0,
            "All-read boundary releases only future reserve")
        accepted += 2
        try refuses("undersized buffer cap") { _ = try QwenResidentMTPLoadResources(placement: valid, maximumBufferBytes: 508_559_359, bound: { $0 }) }
        try refuses("negative bound") { _ = try QwenResidentMTPLoadResources(placement: valid, maximumBufferBytes: Int.max, bound: { _ in -1 }) }
        try refuses("rounding below source") { _ = try QwenResidentMTPLoadResources(placement: valid, maximumBufferBytes: Int.max, bound: { $0 - 1 }) }
        try refuses("sum overflow") { _ = try QwenResidentMTPLoadResources(placement: valid, maximumBufferBytes: Int.max, bound: { _ in Int.max }) }
        try refuses("negative progress") { _ = try exact.pending(after: -1) }
        try refuses("overrun progress") { _ = try exact.pending(after: 35) }

        var progress = QwenResidentMTPReadProgress(placement: valid, resources: exact)
        try refuses("incomplete retirement") { try progress.requireComplete() }
        let first = valid.tensorsInReadOrder[0]
        try refuses("out-of-order read") { _ = try progress.entry(name: head[0].name, shape: head[0].shape, packed: head[0].sourceDType == "U32") }
        try refuses("wrong read dtype") { _ = try progress.entry(name: first.name, shape: first.shape, packed: first.sourceDType != "U32") }
        try refuses("wrong read shape") { _ = try progress.entry(name: first.name, shape: [1], packed: first.sourceDType == "U32") }
        try refuses("wrong completed bytes") { try progress.accept(copiedBytes: first.byteCount - 1) }
        try require(progress.completed == 0, "Failed validation cannot advance resource reserve")
        for (index, entry) in valid.tensorsInReadOrder.enumerated() {
            let before = try progress.pending()
            _ = try progress.entry(name: entry.name, shape: entry.shape, packed: entry.sourceDType == "U32")
            try require(try progress.completed == index && progress.pending().tensorBytes == before.tensorBytes,
                "Admission alone never releases current tensor charge")
            try progress.accept(copiedBytes: entry.byteCount)
            try require(try progress.pending().tensorBytes == before.tensorBytes - entry.byteCount,
                "Only accepted materialization advances current charge")
        }
        try progress.requireComplete(); accepted += 1
        try refuses("read after completion") { _ = try progress.entry(name: first.name, shape: first.shape, packed: false) }
        progress.poison()
        try refuses("poisoned completed reader") { try progress.requireComplete() }
        var failed = QwenResidentMTPReadProgress(placement: valid, resources: exact)
        failed.poison()
        try refuses("read after callback failure") { _ = try failed.entry(name: first.name, shape: first.shape, packed: false) }
        try refuses("advance after callback failure") { try failed.accept(copiedBytes: first.byteCount) }
        try refuses("release reserve after callback failure") { _ = try failed.pending() }
        print("MTP placement/resources/progress: \(accepted) accepted / \(rejected) rejected; metadata-only, no model evaluation")
    }
}
