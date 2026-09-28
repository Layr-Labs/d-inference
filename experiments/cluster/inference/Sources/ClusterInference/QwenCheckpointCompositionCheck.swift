import Foundation
import MLX

private let compositionPrefix = "model.layers.0.mlp.switch_mlp."

private struct CompositionTensorFixture {
    let name: String
    let shape: [Int]
    let dtype: DType
    let bytes: Data

    init(name: String, shape: [Int], dtype: DType, salt: Int) {
        self.name = name; self.shape = shape; self.dtype = dtype
        var bytes = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        for index in 0..<shape.reduce(1, *) {
            if dtype == .uint32 {
                append(UInt32(truncatingIfNeeded: (index + salt) * 2_654_435_761) ^ 0xA5A55A5A)
            } else {
                let bits = (Float((index + salt) % 191 - 95) / 8).bitPattern
                if dtype == .float32 { append(bits) }
                else {
                    precondition(dtype == .bfloat16 && bits & 0xffff == 0)
                    append(UInt16(bits >> 16))
                }
            }
        }
        self.bytes = bytes
    }
}

private func compositionFixtures(metadata: DType) -> [CompositionTensorFixture] {
    ["gate_proj", "up_proj"].enumerated().flatMap { half, projection in
        ["weight", "scales", "biases"].enumerated().map { field, suffix in
            CompositionTensorFixture(name: compositionPrefix + projection + "." + suffix,
                shape: [3, 8, suffix == "weight" ? 16 : 2],
                dtype: suffix == "weight" ? .uint32 : metadata, salt: 11 + half * 29 + field * 47)
        }
    }
}

private let compositionConfiguration = Data("{\"fixture\":\"qwen-checkpoint-composition\"}".utf8)

private func saveCompositionFixture(_ fixtures: [CompositionTensorFixture], directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try compositionConfiguration.write(to: directory.appendingPathComponent("config.json"))
    var mapping: [String: String] = [:]
    // Every ordinary gate/up pair spans two verified files, independently of sort order.
    for shard in 0..<2 {
        let file = "weights-\(shard).safetensors"
        var arrays: [String: MLXArray] = [:]
        for fixture in fixtures where (fixture.name.contains(".up_proj.") ? 1 : 0) == shard {
            arrays[fixture.name] = MLXArray(fixture.bytes, fixture.shape, dtype: fixture.dtype)
            mapping[fixture.name] = file
        }
        try save(arrays: arrays, url: directory.appendingPathComponent(file))
    }
    try JSONSerialization.data(withJSONObject: ["weight_map": mapping], options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    try writeFixtureManifest(directory)
}

/// CPU oracle enumerates fused expert/row/column coordinates directly. It does
/// not reuse descriptor reads, MLX concatenation, or the composition range logic.
private func expectedComposition(_ gate: CompositionTensorFixture, _ up: CompositionTensorFixture,
                                 rows: [Int]) -> Data {
    var bytes = Data()
    for expert in 0..<gate.shape[0] {
        for row in rows {
            let part = row < gate.shape[1] ? gate : up
            let localRow = row % gate.shape[1]
            for column in 0..<gate.shape[2] {
                let index = (expert * gate.shape[1] + localRow) * gate.shape[2] + column
                bytes.append(part.bytes[(index * part.dtype.size)..<((index + 1) * part.dtype.size)])
            }
        }
    }
    return bytes
}

private func requireOwnedComposition(_ array: MLXArray) throws {
    eval(array)
    guard let buffer = try array.evaluatedBufferInfo(), buffer.isUnique,
        buffer.dataOffset == 0, buffer.isRowContiguous, buffer.dataElements == array.size,
        buffer.allocatedBytes >= array.nbytes,
        buffer.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes))
    else { throw ProbeError("Composed expert tensor does not own compact zero-offset storage") }
}

private struct HeldComposition {
    let array: MLXArray
    let bytes: Data
}

private func requireCompositionFailure(_ label: String, _ operation: () throws -> Void) throws {
    var failed = false
    do { try operation() } catch { failed = true }
    guard failed else { throw ProbeError("Checkpoint composition accepted \(label)") }
}

private func readCompositionFixture(_ fixtures: [CompositionTensorFixture], directory: URL) throws
    -> (held: [HeldComposition], rejectedAxes: Int, comparedBytes: Int) {
    let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: compositionConfiguration)
    let descriptors = try tensorDescriptors(checkpoint: checkpoint)
    let composed = try composeQwenCheckpointTensors(descriptors)
    guard descriptors.count == 6, composed.count == 3,
        Set(descriptors.values.map { $0.file.path }) == ["weights-0.safetensors", "weights-1.safetensors"],
        composed.values.reduce(0, { $0 + $1.byteCount }) == fixtures.reduce(0, { $0 + $1.bytes.count })
    else { throw ProbeError("Checkpoint composition did not preserve six source tensors as three canonical tensors") }
    var held: [HeldComposition] = [], rejected = 0, comparedBytes = 0
    for suffix in ["weight", "scales", "biases"] {
        let gate = fixtures.first { $0.name == compositionPrefix + "gate_proj." + suffix }!
        let up = fixtures.first { $0.name == compositionPrefix + "up_proj." + suffix }!
        guard let tensor = composed[compositionPrefix + "gate_up_proj." + suffix],
            tensor.parts.map(\.name) == [gate.name, up.name], tensor.shape == [3, 16, gate.shape[2]],
            tensor.dtype == gate.dtype, tensor.byteCount == gate.bytes.count + up.bytes.count,
            tensor.sourceModulePaths == [compositionPrefix + "gate_proj", compositionPrefix + "up_proj"]
        else { throw ProbeError("Canonical expert shape, source order or byte identity differs") }
        let selections: [(TensorSelection, [Int])] = [
            (.all, Array(0..<16)),
            (.axis(1, [0..<4, 8..<12]), Array(0..<4) + Array(8..<12)),
            (.axis(1, [4..<8, 12..<16]), Array(4..<8) + Array(12..<16)),
            (.axis(1, [0..<8]), Array(0..<8)),
            (.axis(1, [8..<16]), Array(8..<16)),
            (.axis(1, [6..<10]), Array(6..<10)),
        ]
        for (selection, rows) in selections {
            let read = try tensor.read(selection)
            let expected = expectedComposition(gate, up, rows: rows)
            let selectedGate = rows.filter { $0 < 8 }.count
            let selectedUp = rows.count - selectedGate
            let largest = 3 * max(selectedGate, selectedUp) * gate.shape[2] * gate.dtype.size
            try requireOwnedComposition(read.array)
            guard read.array.shape == [3, rows.count, gate.shape[2]], read.array.dtype == gate.dtype,
                read.array.asData().data == expected, read.copiedBytes == expected.count,
                read.array.nbytes == expected.count, read.largestHostTensorBytes == largest
            else { throw ProbeError("Selected expert fusion differs from CPU values or selected source byte accounting") }
            held.append(HeldComposition(array: read.array, bytes: expected))
            comparedBytes += expected.count
        }
        for axis in [0, 2] {
            try requireCompositionFailure("unsupported fused selection axis \(axis)") {
                _ = try tensor.read(.axis(axis, [0..<1]))
            }
            rejected += 1
        }
    }
    try checkpoint.checkUnchanged()
    return (held, rejected, comparedBytes)
}

private func malformedCompositionFixtures() -> [(String, [CompositionTensorFixture])] {
    let good = compositionFixtures(metadata: .float32)
    let gateWeight = compositionPrefix + "gate_proj.weight"
    let upWeight = compositionPrefix + "up_proj.weight"
    let upScale = compositionPrefix + "up_proj.scales"
    func replacing(_ name: String, shape: [Int], dtype: DType) -> [CompositionTensorFixture] {
        good.filter { $0.name != name } + [CompositionTensorFixture(name: name, shape: shape, dtype: dtype, salt: 31)]
    }
    return [
        ("missing-up-half", good.filter { $0.name != upWeight }),
        ("lone-up-half", good.filter { $0.name != gateWeight }),
        ("fused-split-collision", good + [CompositionTensorFixture(
            name: compositionPrefix + "gate_up_proj.weight", shape: [3, 16, 16], dtype: .uint32, salt: 61)]),
        ("shape-mismatch", replacing(upScale, shape: [3, 4, 4], dtype: .float32)),
        ("dtype-mismatch", replacing(upScale, shape: [3, 8, 2], dtype: .bfloat16)),
        ("ordinary-linear-bias", good + [CompositionTensorFixture(
            name: compositionPrefix + "gate_proj.bias", shape: [3, 8], dtype: .float32, salt: 71)]),
    ]
}

func checkQwenCheckpointComposition() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cluster-checkpoint-composition-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var comparedBytes = 0, selectedTensors = 0, rejectedAxes = 0
    for metadata in [DType.float32, .bfloat16] {
        let path = directory.appendingPathComponent(String(describing: metadata))
        let fixtures = compositionFixtures(metadata: metadata)
        try saveCompositionFixture(fixtures, directory: path)
        let checked = try readCompositionFixture(fixtures, directory: path)
        // Descriptors and temporary MLX pieces are out of scope before modifying files.
        for shard in 0..<2 {
            let file = path.appendingPathComponent("weights-\(shard).safetensors")
            let length = try Data(contentsOf: file).count
            let handle = try FileHandle(forWritingTo: file)
            do { try handle.write(contentsOf: Data(repeating: 0xCC, count: length)); try handle.close() }
            catch { try? handle.close(); throw error }
        }
        try FileManager.default.removeItem(at: path)
        for held in checked.held {
            try requireOwnedComposition(held.array)
            guard held.array.asData().data == held.bytes else {
                throw ProbeError("Composed expert tensor changed after source overwrite/deletion")
            }
        }
        comparedBytes += checked.comparedBytes
        selectedTensors += checked.held.count
        rejectedAxes += checked.rejectedAxes
    }
    let malformed = malformedCompositionFixtures()
    for (label, fixtures) in malformed {
        let path = directory.appendingPathComponent(label)
        try saveCompositionFixture(fixtures, directory: path)
        let checkpoint = try VerifiedCheckpoint(directory: path, configurationData: compositionConfiguration)
        // Manifest/index validation must succeed first: rejection must occur at
        // the composition boundary, not because the saved fixture is unreadable.
        let descriptors = try tensorDescriptors(checkpoint: checkpoint)
        try requireCompositionFailure(label) { _ = try composeQwenCheckpointTensors(descriptors) }
        try checkpoint.checkUnchanged()
    }
    struct Result: Encodable {
        let kind = "qwen_checkpoint_composition_parity"
        let sourceTensorCountPerFixture = 6
        let canonicalTensorCountPerFixture = 3
        let sourceFilesPerFixture = 2
        let metadataDTypes = ["float32", "bfloat16"]
        let selectedTensors: Int
        let comparedBytes: Int
        let rejectedSelectionAxes: Int
        let rejectedMalformedCompositions: [String]
        let bothRankRowSelections = true
        let independentCPUOracle = true
        let uniqueZeroOffsetOwnedBuffers = true
        let survivedSourceOverwriteAndDeletion = true
        let correctnessOnly = true
    }
    try emitJSON(Result(selectedTensors: selectedTensors, comparedBytes: comparedBytes,
        rejectedSelectionAxes: rejectedAxes, rejectedMalformedCompositions: malformed.map(\.0)))
}
