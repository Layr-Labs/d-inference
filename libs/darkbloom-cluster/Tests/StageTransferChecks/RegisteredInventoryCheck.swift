import Foundation

/// The storage commitment a local load derives, rebuilt from the pinned
/// content inventory, the registered configuration and the specification's
/// own pins. No file of the artifact is read and no model is constructed.
func storageCommitmentSHA256(inventory: LayerStageTensorContentInventory, configuration: Data,
                             specification: QwenDenseRegisteredSpecification, cut: Int) throws -> String {
    let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<specification.layers])
    let sources = try QwenStageSourceTensorManifest.tensors(inventory, bf16ConversionEnabled: true)
    let byName = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceName, $0) })
    let parameters = try plan.parameters(canonicalSourceNames: sources.map(\.sourceName))
    func layout(_ entries: [String]) -> String { sha256(Data(entries.sorted().joined(separator: "\n").utf8)) }
    let summaries = try plan.stages.map { stage -> QwenStageStorageSummary in
        let active = try parameters.filter { $0.stage == stage.index }.sorted { $0.localName < $1.localName }.map { parameter in
            guard let tensor = byName[parameter.sourceName] else { throw ProbeError("Unowned source tensor") }
            return QwenStageActiveTensor(sourceName: parameter.sourceName, localName: parameter.localName,
                shape: tensor.shape, sourceDType: tensor.sourceDType, loadedDType: tensor.loadedDType, byteCount: tensor.byteCount)
        }
        // The placeholders the loader installs for the modules a stage does not run:
        // the final norm's weight [hidden], and a one-row head or embedding [1, hidden].
        let inert = stage.inertModules.sorted { $0.path < $1.path }.map {
            "\($0.path).weight:bfloat16:\($0.path.hasSuffix("model.norm") ? [specification.hidden] : [1, specification.hidden])"
        }
        let activeLayout = active.map { "\($0.localName):\($0.loadedDType):\($0.shape)" }
        return QwenStageStorageSummary(stageIndex: stage.index,
            constructionConfigurationSHA256: sha256(stage.constructionConfiguration), stagePlanSHA256: stage.fingerprint,
            activeMappingSHA256: sha256(try canonicalJSONData(active)), activeParameterLayoutSHA256: layout(activeLayout),
            parameterLayoutSHA256: layout(activeLayout + inert), loadedTensorBytes: active.reduce(0) { $0 + $1.byteCount },
            activeTensorCount: active.count, inertTensorBytes: inert.count * specification.hidden * 2, inertTensorCount: inert.count)
    }
    return sha256(try canonicalJSONData(QwenLayerStageStorageCommitment(schemaVersion: 1,
        verifiedAggregateSHA256: specification.artifactSHA256, sourceConfigurationSHA256: sha256(configuration),
        planSHA256: plan.fingerprint, sourceTensorManifestSHA256: sha256(try canonicalJSONData(sources)),
        sourceModelTensorBytes: inventory.payloadBytes,
        largestSourceTensorBytes: inventory.records.map { $0.source.layout.byteCount }.max() ?? 0,
        sourceTensorCount: sources.count, canonicalTensorCount: sources.count, bf16ConversionEnabled: true,
        stages: summaries)))
}

func checkRegisteredInventory(_ inputs: RetainedQwenInputs, configuration: Data,
                              _ checks: StageTransferChecks) throws {
    guard let nine = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen35NineB }),
          let twentySeven = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen38TwentySevenB }),
          let document = QwenRegisteredContentInventory.document(.qwen35NineB),
          let inventory = try QwenRegisteredContentInventory.admit(nine) else {
        throw ProbeError("Registered 9B content inventory is unavailable")
    }
    // Self-check 1: the embedded document hashes to the pin.
    try checks.require("the registered 9B document is canonical and its SHA-256 is the specification's pin",
        nine.contentInventorySHA256 == "e636e715e70904e6c6ae7a59bd9244fbeaf199fa5972aaa808499646cff7e1c0"
        && sha256(Data(document.utf8)) == nine.contentInventorySHA256 && inventory.encodedSHA256 == nine.contentInventorySHA256
        && inventory.encoded() == Data(document.utf8))
    // Self-check 2: without file, offset and content it is the already-pinned layout inventory.
    try checks.require("dropping content from the 9B inventory reproduces the pinned inventory fingerprint",
        inventory.layoutInventorySHA256 == "4a543a467846927736165c44a68802ad15794482ffdf3a1c60113a38c6abfb51"
        && inventory.layoutInventorySHA256 == nine.inventorySHA256
        && inventory.records.count == nine.tensorCount && inventory.payloadBytes == nine.sourceBytes
        && inventory.records.map { $0.source.layout.byteCount }.max() == nine.largestTensorBytes
        && Set(inventory.records.map { $0.source.layout.canonicalName }) == Set(inputs.nine.canonicalTensors.map(\.name)))
    // Self-check 3: its file and offset fields give the storage commitment that verified
    // local loads of the registered artifact recorded for each cut (stage check receipts).
    try checks.require("the registered configuration fixture is the pinned configuration",
        sha256(configuration) == nine.configurationSHA256 && configuration == inputs.nine.configuration)
    for (cut, recorded) in [
        (4, "e2e41be21c400e180645a3c0a10e8905ca71b4a48d558c8406c5dd0e66f0bb4f"),
        (8, "2b848d3d8f0302948d49ab3215d6fcd1bce55322e22cfa65006f677ea2ef536f"),
        (12, "2004594baaa2f8db889d4d674cb5290a89dbbfa5582dbade9c73de5d5fc95c85"),
        (16, "a3a852726b2cce3420a13eb345c46903deafc07ce2771ce678e1a0675b7e341d"),
    ] {
        try checks.require("the 9B inventory alone reproduces the recorded cut \(cut) storage commitment",
            try storageCommitmentSHA256(inventory: inventory, configuration: configuration, specification: nine, cut: cut) == recorded)
    }
    // One offset moved by a byte is another commitment: the fields are load-bearing.
    var moved = inventory.records
    let last = moved[moved.count - 1]
    moved[moved.count - 1] = try .init(source: .init(layout: last.source.layout, sourceFile: last.source.sourceFile,
        sourceOffset: last.source.sourceOffset + 1), contentSHA256: last.contentSHA256)
    try checks.require("a moved offset changes the derived commitment",
        try storageCommitmentSHA256(inventory: .init(records: moved), configuration: configuration, specification: nine, cut: 4)
            != "e2e41be21c400e180645a3c0a10e8905ca71b4a48d558c8406c5dd0e66f0bb4f")

    // Every tensor a transfer plans has a pinned record of the same shape and dtype.
    for cut in [4, 8, 12, 16] {
        let stages = try retainedDeliveredStages(inputs.nine, cut: cut, layers: 32, stages: [0, 1])
        let session = try QwenStageTransferSession(loadAgreementFingerprint: String(repeating: "a", count: 64),
            plan: QwenStageTransferPlan(stages: stages, limits: .proposed), inventory: inventory)
        try checks.require("every tensor of a cut \(cut) transfer has its pinned 9B record",
            session.records.count == 927 && Set(session.records.map(\.contentSHA256)).count > 900
            && zip(session.plan.tensors, session.records).allSatisfy { $0.byteCount == $1.source.layout.byteCount })
    }

    try checks.require("a model nobody has inventoried has no pin and no document",
        twentySeven.contentInventorySHA256 == nil && QwenRegisteredContentInventory.document(.qwen38TwentySevenB) == nil
        && (try QwenRegisteredContentInventory.admit(twentySeven)) == nil)
    func admit(document: String?, pin: String?, layout: String = nine.inventorySHA256) throws {
        _ = try QwenRegisteredContentInventory.admit(document: document, pin: pin, layoutInventorySHA256: layout)
    }
    try checks.refuses("a pin with no document", because: "needs both its document and its pin") {
        try admit(document: nil, pin: nine.contentInventorySHA256)
    }
    try checks.refuses("a document with no pin", because: "needs both its document and its pin") {
        try admit(document: document, pin: nil)
    }
    try checks.refuses("a document that differs from its pin", because: "differs from its pinned SHA-256") {
        try admit(document: document, pin: String(repeating: "0", count: 64))
    }
    try checks.refuses("a pinned document of another layout inventory", because: "differs from the pinned layout inventory") {
        try admit(document: document, pin: nine.contentInventorySHA256, layout: twentySeven.inventorySHA256)
    }
    try checks.refuses("a pinned document that is not canonical", because: "does not end with a newline") {
        let cut = String(document.dropLast())
        try admit(document: cut, pin: sha256(Data(cut.utf8)))
    }
    let source = try QwenRegisteredContentInventory.swiftSource(model: .qwen35NineB, document: Data(document.utf8))
    try checks.require("the generated source embeds the document between a blank-line-terminated literal",
        source.hasPrefix("// Generated by `darkbloom-cluster-stage-check content-inventory`")
        && source.contains("enum QwenRegistered9BContentInventory {\n    static let document = \"\"\"\n    layer-stage-tensor-content-inventory-v1\n    927\n")
        && source.hasSuffix("\n\n    \"\"\"\n}\n")
        && source.split(separator: "\n").filter { $0.hasPrefix("    language_model.") }.count == 927)
}
