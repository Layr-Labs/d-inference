import Foundation
import CryptoKit

struct ConstructorProbeFixtureInput: Decodable {
    struct Model: Decodable { let configuration: Data, manifest: Data }
    let nine: Model, twentySeven: Model
}
struct ConstructorProbeFixtureResult: Encodable {
    let kind = "qwen_dense_constructor_admission_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    let modelConstructed = false, nativeWorkPerformed = false, modelPayloadRead = false
    let syntheticCheckpointIOPerformed = true, constructorProbeExecuted = false
}

func checkConstructorProbe(_ input: ConstructorProbeFixtureInput) throws -> ConstructorProbeFixtureResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ label: String, _ value: Bool) throws {
        guard value else { throw ProbeError("Constructor fixture failed: " + label) }
        accepted.append(label)
    }
    func reject(_ label: String, _ expected: String? = nil, _ body: () throws -> Void) throws {
        do { try body() } catch {
            if let expected, String(describing: error) != expected { throw ProbeError("Wrong constructor fixture error: \(error)") }
            rejected.append(label); return
        }
        throw ProbeError("Constructor fixture accepted: " + label)
    }
    let environment = QwenLongPrefillArithmeticEnvironment.requiredValues
    for (model, fixture, other) in [(QwenRegisteredDenseModel.qwen35NineB, input.nine, QwenRegisteredDenseModel.qwen38TwentySevenB),
                                   (.qwen38TwentySevenB, input.twentySeven, .qwen35NineB)] {
        let value = try QwenDenseConstructorAdmission.admit(model: model, configuration: fixture.configuration,
            manifest: fixture.manifest, environment: environment)
        try require(model.rawValue + " exact metadata only", value.plan.layers == value.specification.layers &&
            value.plan.stages[0].sourceRange.upperBound == value.plan.layers / 2 &&
            !value.weightMaterializationAuthorized && !value.forwardExecutionAuthorized &&
            !value.independentResourceAdmissionEstablished && !value.providerEligibilityEstablished)
        try reject(model.rawValue + " selected model mismatch") {
            _ = try QwenDenseConstructorAdmission.admit(model: other, configuration: fixture.configuration,
                manifest: fixture.manifest, environment: environment)
        }
        try reject(model.rawValue + " raw config spelling changed") {
            _ = try QwenDenseConstructorAdmission.admit(model: model, configuration: fixture.configuration + Data([32]),
                manifest: fixture.manifest, environment: environment)
        }
        try reject(model.rawValue + " raw manifest spelling changed") {
            _ = try QwenDenseConstructorAdmission.admit(model: model, configuration: fixture.configuration,
                manifest: fixture.manifest + Data([32]), environment: environment)
        }
        for key in environment.keys.sorted() {
            var missing = environment; missing.removeValue(forKey: key)
            try reject(model.rawValue + " missing " + key) {
                _ = try QwenDenseConstructorAdmission.admit(model: model, configuration: fixture.configuration,
                    manifest: fixture.manifest, environment: missing)
            }
            var wrong = environment; wrong[key] = "0"
            try reject(model.rawValue + " wrong " + key) {
                _ = try QwenDenseConstructorAdmission.admit(model: model, configuration: fixture.configuration,
                    manifest: fixture.manifest, environment: wrong)
            }
        }
        for key in QwenLongPrefillArithmeticEnvironment.requiredAbsentNames {
            var present = environment; present[key] = ""
            try reject(model.rawValue + " present empty " + key) {
                _ = try QwenDenseConstructorAdmission.admit(model: model, configuration: fixture.configuration,
                    manifest: fixture.manifest, environment: present)
            }
        }
    }
    let arguments = ["--mode", QwenDenseConstructorCLI.mode, "--model-dir", "/invented-model",
        "--registered-dense-profile", "registered_qwen35_9b", "--timeout-seconds", "120"]
    let legacy = ["--mode", "qwen-layer-stage-compare", "--tokens-file", QwenDenseConstructorCLI.mode]
    try require("CLI does not intercept unrelated token filename", !QwenDenseConstructorCLI.isRequested(legacy))
    let duplicateMode = arguments + ["--mode", QwenDenseConstructorCLI.mode]
    try require("CLI duplicate explicit constructor mode reaches strict parser", QwenDenseConstructorCLI.isRequested(duplicateMode))
    try reject("CLI duplicate explicit constructor mode") { _ = try QwenDenseConstructorCLI(arguments: duplicateMode) }
    for model in QwenRegisteredDenseModel.allCases {
        var args = arguments; args[5] = model.rawValue
        let value = try QwenDenseConstructorCLI(arguments: args)
        try require("CLI " + model.rawValue, value.model == model && value.timeoutSeconds == 120)
    }
    let reversed = stride(from: 6, through: 0, by: -2).flatMap { Array(arguments[$0...($0 + 1)]) }
    try require("CLI pair order independent", try QwenDenseConstructorCLI(arguments: reversed).model == .qwen35NineB)
    for timeout in ["1", "300"] {
        var args = arguments; args[7] = timeout
        try require("CLI timeout " + timeout, try QwenDenseConstructorCLI(arguments: args).timeoutSeconds == Int(timeout))
    }
    for (index, replacement, label) in [(1, "qwen-layer-stage-compare", "other mode"),
        (6, "--stage-cut", "cut flag"), (6, "--prefill-token-count", "prefill flag"),
        (6, "--prefill-owner-trace", "trace flag"), (6, "--model-dir", "duplicate flag"),
        (5, "registered_qwen35_27b", "unknown profile"), (3, "relative", "relative path"),
        (3, "/invalid\u{0}path", "NUL path")] {
        var args = arguments; args[index] = replacement
        try reject("CLI " + label) { _ = try QwenDenseConstructorCLI(arguments: args) }
    }
    try reject("CLI missing pair") { _ = try QwenDenseConstructorCLI(arguments: Array(arguments.dropLast(2))) }
    for timeout in ["0", "301", "-1", "1.0", "01", "x", "9999999999999999999999999999999999"] {
        var args = arguments; args[7] = timeout
        try reject("CLI timeout " + timeout) { _ = try QwenDenseConstructorCLI(arguments: args) }
    }
    // Actual Foundation VerifiedCheckpoint on six invented bytes. This directly
    // exercises the new configuration reuse guard without model construction.
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("qwen-constructor-config-" + UUID().uuidString)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: directory) }
    let config = Data("{}\n".utf8), payload = Data([7, 8, 9])
    try config.write(to: directory.appendingPathComponent("config.json"))
    try payload.write(to: directory.appendingPathComponent("payload.bin"))
    var aggregateInput = Data(); aggregateInput.append(contentsOf: SHA256.hash(data: config))
    aggregateInput.append(contentsOf: SHA256.hash(data: payload))
    let manifest = CheckpointManifest(aggregate_sha256: sha256(aggregateInput), file_count: 2,
        total_size_bytes: config.count + payload.count,
        files: [.init(path: "config.json", sha256: sha256(config), size_bytes: config.count),
                .init(path: "payload.bin", sha256: sha256(payload), size_bytes: payload.count)])
    let encoded = try JSONEncoder().encode(manifest)
    try encoded.write(to: directory.appendingPathComponent("manifest.json"))
    for pinned in [false, true] {
        let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: manifest.aggregate_sha256,
            expectedManifestSHA256: pinned ? sha256(encoded) : nil)
        try checkpoint.requireConfiguration(config); try checkpoint.checkUnchanged()
        try require("verified configuration reuse " + String(pinned), checkpoint.configurationSHA256 == sha256(config) &&
            checkpoint.verifiedManifestSHA256 == (pinned ? sha256(encoded) : nil))
    }
    let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: config)
    try reject("reuse rejects same-length other configuration", "Reused checkpoint configuration differs from verified configuration") {
        try checkpoint.requireConfiguration(Data("[]\n".utf8))
    }
    try reject("legacy payload cap remains enforced", "Checkpoint payload exceeds the requested byte limit") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config, maximumPayloadBytes: 0)
    }
    guard accepted.count == 11, rejected.count == 41 else {
        throw ProbeError("Constructor fixture counts changed: \(accepted.count)/\(rejected.count)")
    }
    return .init(accepted: accepted, rejected: rejected)
}
