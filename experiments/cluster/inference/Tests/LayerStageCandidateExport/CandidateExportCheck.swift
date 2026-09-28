import Foundation
import Darwin

struct CandidateExportRetainedInputs: Decodable {
    struct Tensor: Decodable { let name: String }
    struct Model: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
    let nine: Model
    let twentySeven: Model
}

struct CandidateExportCheckResult: Encodable {
    let kind = "qwen_layer_stage_candidate_export_check"
    let accepted: [String], rejected: [String]
    let metadataOnly = true, sourcePayloadRead = false, runtimeEligibilityEstablished = false
}

func checkCandidateExport(_ retained: CandidateExportRetainedInputs) throws -> CandidateExportCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ name: String, _ value: Bool) throws {
        guard value else { throw ProbeError("Candidate export check failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Candidate export check accepted: " + name)
    }
    func export(_ config: Data, _ names: [String]) throws -> QwenCandidateExportCatalog {
        let raw = try QwenCandidateExportEncoding.data(names)
        return try QwenCandidateExport.make(configuration: config, canonicalNamesJSON: raw,
            expectedConfigurationSHA256: sha256(config), expectedCanonicalNamesSHA256: sha256(raw))
    }
    func coverage(_ catalog: QwenCandidateExportCatalog, names: [String], layers: Int, namespace: String) throws {
        for candidate in catalog.candidates {
            let parameters = candidate.stages.flatMap(\.parameters)
            guard Set(parameters.map(\.sourceName)) == Set(names), parameters.count == names.count,
                  Set(parameters.map { "\($0.stage):\($0.localName)" }).count == parameters.count,
                  candidate.stages.map(\.sourceLayerRange) == [[0, candidate.cut], [candidate.cut, layers]],
                  candidate.stages.flatMap(\.state).map({ $0.layer.globalIndex }) == Array(0..<layers) else {
                throw ProbeError("Candidate export lost complete ownership")
            }
            for stage in candidate.stages {
                guard stage.parameterCount == stage.parameters.count, stage.stateLayerCount == stage.state.count else {
                    throw ProbeError("Candidate export count differs from its records")
                }
                for parameter in stage.parameters {
                    let prefix = namespace + "model.layers."
                    if parameter.sourceName.hasPrefix(prefix) {
                        let global = parameter.sourceName.dropFirst(prefix.count).split(separator: ".", maxSplits: 1)
                        let local = parameter.localName.dropFirst(prefix.count).split(separator: ".", maxSplits: 1)
                        guard parameter.localName.hasPrefix(prefix), global.count == 2, local.count == 2,
                              let g = Int(global[0]), let l = Int(local[0]),
                              g == l + stage.sourceLayerRange[0], global[1] == local[1],
                              parameter.stage == stage.stageIndex,
                              (stage.sourceLayerRange[0]..<stage.sourceLayerRange[1]).contains(g) else {
                            throw ProbeError("Candidate export changed an inverse layer mapping")
                        }
                    } else {
                        let isEmbedding = parameter.sourceName.hasPrefix(namespace + "model.embed_tokens.")
                        guard parameter.stage == (isEmbedding ? 0 : 1), parameter.sourceName == parameter.localName else {
                            throw ProbeError("Candidate export changed embedding/norm/head ownership")
                        }
                    }
                }
                for state in stage.state {
                    let full = (state.layer.globalIndex + 1) % 4 == 0
                    guard state.layer.localIndex == state.layer.globalIndex - stage.sourceLayerRange[0],
                          state.layer.kind == (full ? "full_attention" : "linear_attention"),
                          state.components == (full ? ["kv.keys", "kv.values", "kv.position_offsets"] : ["conv", "ssm"]) else {
                        throw ProbeError("Candidate export changed state ownership or interval phase")
                    }
                }
            }
        }
    }

    for (name, model, layers, cuts) in [
        ("retained9B", retained.nine, 32, [4, 8, 12, 16, 20, 24, 28]),
        ("retained27B", retained.twentySeven, 64, [4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60]),
    ] {
        let names = model.canonicalTensors.map(\.name)
        let catalog = try export(model.configuration, names)
        try require(name + " exact metadata candidate set", catalog.candidates.map(\.cut) == cuts)
        try coverage(catalog, names: names, layers: layers, namespace: "language_model.")
        accepted.append(name + " every candidate conserves parameter/state ownership")
        let record = try QwenCandidateExportEncoding.record(catalog)
        try require(name + " one bounded complete JSON record", record.last == 10
            && record.count <= QwenCandidateExport.maximumOutputBytes
            && (try JSONSerialization.jsonObject(with: record) as? [String: Any]) != nil)
        let repeated = try export(model.configuration, names)
        try require(name + " deterministic full export", record == QwenCandidateExportEncoding.record(repeated))
        let reversed = try export(model.configuration, Array(names.reversed()))
        try require(name + " name-order identity separation",
            catalog.canonicalNamesSHA256 == reversed.canonicalNamesSHA256
            && catalog.canonicalNamesRawSHA256 != reversed.canonicalNamesRawSHA256
            && QwenCandidateExportEncoding.data(catalog.candidates) == QwenCandidateExportEncoding.data(reversed.candidates))
        let reformatted = try export(model.configuration + Data("\n".utf8), names)
        try require(name + " native Plan retains raw configuration binding",
            catalog.sourceConfigurationSHA256 != reformatted.sourceConfigurationSHA256
            && zip(catalog.candidates, reformatted.candidates).allSatisfy { pair in
                pair.0.planFingerprint != pair.1.planFingerprint && zip(pair.0.stages, pair.1.stages).allSatisfy { stages in
                    stages.0.constructionConfigurationSHA256 == stages.1.constructionConfigurationSHA256
                        && stages.0.stageFingerprint != stages.1.stageFingerprint
                }
            })
        try require(name + " no verification or execution claim", catalog.metadataOnly
            && !catalog.actualSanitizerVerified && !catalog.sourceDescriptorsVerified && !catalog.modelConstructed
            && !catalog.checkpointWeightsRead && !catalog.modelPayloadsVerified && !catalog.allocationMeasured
            && !catalog.runtimeEligibilityEstablished && !catalog.performanceQualified)
    }

    for form in CandidateFixture.Form.allCases {
        let tiny = CandidateFixture(layers: 10, form: form)
        let config = try candidateJSON(tiny.object)
        let catalog = try export(config, tiny.canonicalNames)
        try coverage(catalog, names: tiny.canonicalNames, layers: 10, namespace: tiny.namespace)
        try require("unaligned final end and exact ownership " + String(describing: form),
            catalog.candidates.map(\.cut) == [4] && catalog.candidates[0].stages.map(\.stateLayerCount) == [4, 6])
    }
    let tiny = CandidateFixture(layers: 12, form: .nestedWrapper)
    let config = try candidateJSON(tiny.object), names = tiny.canonicalNames
    let rawNames = try QwenCandidateExportEncoding.data(names)
    func rawExport(_ suppliedConfiguration: Data? = nil, _ suppliedNames: Data? = nil) throws {
        let configuration = suppliedConfiguration ?? config, raw = suppliedNames ?? rawNames
        _ = try QwenCandidateExport.make(configuration: configuration, canonicalNamesJSON: raw,
            expectedConfigurationSHA256: sha256(configuration), expectedCanonicalNamesSHA256: sha256(raw))
    }
    let excluded = try export(config, names + ["mtp.layers.0.weight", "vision_tower.weight"])
    try require("explicit excluded names remain visible", excluded.candidates.allSatisfy {
        $0.excludedCanonicalSourceNames == ["mtp.layers.0.weight", "vision_tower.weight"]
            && $0.stages.flatMap(\.parameters).count == names.count
    })
    try reject("wrong raw configuration pin") {
        _ = try QwenCandidateExport.make(configuration: config, canonicalNamesJSON: rawNames,
            expectedConfigurationSHA256: String(repeating: "0", count: 64), expectedCanonicalNamesSHA256: sha256(rawNames))
    }
    try reject("wrong raw names pin") {
        _ = try QwenCandidateExport.make(configuration: config, canonicalNamesJSON: rawNames,
            expectedConfigurationSHA256: sha256(config), expectedCanonicalNamesSHA256: String(repeating: "0", count: 64))
    }
    for data in [Data(), Data(repeating: 32, count: QwenCandidateExport.maximumConfigurationBytes + 1)] {
        try reject("configuration byte bound " + String(data.count)) { try rawExport(data) }
    }
    for (index, raw) in [Data(), Data(repeating: 32, count: QwenCandidateExport.maximumNamesBytes + 1),
                Data("{}".utf8), Data("[1]".utf8), Data("[]".utf8)].enumerated() {
        try reject("names input case " + String(index)) { try rawExport(config, raw) }
    }
    for (index, changed) in [names + [names[0]], Array(names.dropFirst()), names + ["unknown.weight"],
                    names + [String(repeating: "x", count: 513)], names + ["mtp.bad\nname"],
                    (0...QwenCandidateExport.maximumNames).map { "mtp.\($0)" }].enumerated() {
        try reject("invalid canonical names case " + String(index)) {
            try rawExport(config, QwenCandidateExportEncoding.data(changed))
        }
    }
    for (index, text) in [#"{"x":0.1,"\u0078":2}"#, #"{"x":1,"x":2}"#,
                 #"{"x":01}"#, #"{"x":1e999}"#, #"{"x":1-2}"#,
                 #"{"x":NaN}"#, #"{"x":1.}"#,
                 String(repeating: "[", count: 66) + "0.1" + String(repeating: "]", count: 66)].enumerated() {
        try reject("strict configuration scanner case " + String(index)) {
            try validateCandidateExportConfigurationJSON(Data(text.utf8))
        }
    }
    try validateCandidateExportConfigurationJSON(Data(#"{"x":-1.25e-3,"s":"1.2\\\"3","a":[true,null,0]}"#.utf8))
    accepted.append("config scanner preserves floats and escaped numeric strings")
    try reject("native metadata refusal remains authoritative") {
        try rawExport(tiny.changingText("num_experts", to: 8))
    }
    try reject("no native legal cut") {
        let short = CandidateFixture(layers: 7, form: .text)
        _ = try export(candidateJSON(short.object), short.canonicalNames)
    }
    let record = try export(config, names)
    let encoded = try QwenCandidateExportEncoding.record(record)
    try require("exact output bound includes newline", encoded == QwenCandidateExportEncoding.record(record, maximumBytes: encoded.count))
    try reject("output bound refuses whole record") { _ = try QwenCandidateExportEncoding.record(record, maximumBytes: encoded.count - 1) }

    let args = ["--config", "config.json", "--config-sha256", sha256(config),
                "--canonical-names", "names.json", "--canonical-names-sha256", sha256(rawNames)]
    let cli = try QwenCandidateExportCLI(arguments: args)
    var observed: [String] = []
    let cliRecord = try cli.encoded { url, cap in
        observed.append(url.lastPathComponent + ":" + String(cap))
        return url.lastPathComponent == "config.json" ? config : rawNames
    }
    try require("CLI uses exact bounded inputs and same complete record", cliRecord == encoded
        && observed == ["config.json:1048576", "names.json:2097152"])
    var unknown = args; unknown[0] = "--model-dir"
    var duplicate = args; duplicate[4] = "--config"
    var uppercase = args; uppercase[3] = String(repeating: "A", count: 64)
    var badPath = args; badPath[1] = "bad\0path"
    for (index, invalid) in [[], Array(args.dropLast()), args + ["--stage-cut", "4"], unknown, duplicate, uppercase, badPath].enumerated() {
        try reject("strict CLI case " + String(index)) { _ = try QwenCandidateExportCLI(arguments: invalid) }
    }
    // Actual tiny metadata files exercise the default reader, not an injected
    // claim about reads. No checkpoint tensor bytes are created or consumed.
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent("candidate-export-check-" + UUID().uuidString)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: temporary) }
    let configFile = temporary.appendingPathComponent("config.json")
    let namesFile = temporary.appendingPathComponent("names.json")
    try config.write(to: configFile); try rawNames.write(to: namesFile)
    let snapshot = try QwenCandidateExportInput.read(configFile, maximumBytes: config.count)
    try require("actual regular snapshot at exact bound", snapshot == config)
    var fileArgs = args; fileArgs[1] = configFile.path; fileArgs[5] = namesFile.path
    let fileCLI = try QwenCandidateExportCLI(arguments: fileArgs)
    try require("actual default reader preserves complete export", fileCLI.encoded() == encoded)
    let symlink = temporary.appendingPathComponent("symlink")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: configFile)
    try reject("actual symlink refused before read") {
        _ = try QwenCandidateExportInput.read(symlink, maximumBytes: config.count)
    }
    let fifo = temporary.appendingPathComponent("fifo")
    guard mkfifo(fifo.path, 0o600) == 0 else { throw ProbeError("Could not create FIFO metadata fixture") }
    try reject("actual FIFO refused without a writer") {
        _ = try QwenCandidateExportInput.read(fifo, maximumBytes: 8)
    }
    let oversized = temporary.appendingPathComponent("oversized")
    try Data(repeating: 32, count: 9).write(to: oversized)
    try reject("actual oversize file refused") {
        _ = try QwenCandidateExportInput.read(oversized, maximumBytes: 8)
    }
    let empty = temporary.appendingPathComponent("empty")
    try Data().write(to: empty)
    try reject("actual empty file refused") {
        _ = try QwenCandidateExportInput.read(empty, maximumBytes: 8)
    }
    try reject("actual directory refused") {
        _ = try QwenCandidateExportInput.read(temporary, maximumBytes: 8)
    }
    fileArgs[3] = String(repeating: "0", count: 64)
    let wrongPin = try QwenCandidateExportCLI(arguments: fileArgs)
    try reject("actual snapshot still requires its raw pin") { _ = try wrongPin.encoded() }
    return CandidateExportCheckResult(accepted: accepted, rejected: rejected)
}
