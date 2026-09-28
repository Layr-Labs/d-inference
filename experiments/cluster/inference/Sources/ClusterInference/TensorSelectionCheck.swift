import Foundation
import MLX

private struct SelectionFixture {
    let name: String
    let shape: [Int]
    let dtype: DType
    let bytes: Data
    let selections: [TensorSelection]

    init(name: String, shape: [Int], dtype: DType, selections: [TensorSelection]) {
        self.name = name; self.shape = shape; self.dtype = dtype; self.selections = selections
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for index in 0..<shape.reduce(1, *) {
            switch dtype {
            case .uint32: append(UInt32(truncatingIfNeeded: index * 2_654_435_761) ^ 0xA5A55A5A)
            case .float32: append((Float(index - 73) / 16).bitPattern)
            case .float16: append(Float16(Float(index % 191 - 95) / 8).bitPattern)
            case .bfloat16:
                // These small multiples of 1/8 are exactly representable in BF16.
                let bits = (Float(index % 191 - 95) / 8).bitPattern
                precondition(bits & 0xffff == 0)
                append(UInt16(bits >> 16))
            default: preconditionFailure("Unsupported selection fixture dtype")
            }
        }
        bytes = data
    }

    /// Independent CPU oracle: enumerate every original element, decode its
    /// coordinate, and keep it iff that coordinate belongs to a selected range.
    /// This does not copy the reader's contiguous-block/outer-stride algorithm.
    func expected(_ selection: TensorSelection) -> (shape: [Int], bytes: Data) {
        guard case .axis(let axis, let ranges) = selection else { return (shape, bytes) }
        var outputShape = shape
        outputShape[axis] = ranges.reduce(0) { $0 + $1.count }
        var output = Data()
        for index in 0..<shape.reduce(1, *) {
            var remaining = index
            var coordinates = [Int](repeating: 0, count: shape.count)
            for dimension in shape.indices.reversed() {
                coordinates[dimension] = remaining % shape[dimension]
                remaining /= shape[dimension]
            }
            if ranges.contains(where: { $0.contains(coordinates[axis]) }) {
                output.append(bytes[(index * dtype.size)..<((index + 1) * dtype.size)])
            }
        }
        return (outputShape, output)
    }
}

private func selectionFixtures() -> [SelectionFixture] {
    [
        SelectionFixture(name: "vector", shape: [192], dtype: .float32, selections: [
            .all, .axis(0, [0..<1, 3..<7, 16..<48, 128..<192]), .axis(0, [0..<192]),
            .axis(0, [191..<192]), .axis(0, [0..<64, 64..<192]),
        ]),
        SelectionFixture(name: "packed_matrix", shape: [9, 320], dtype: .uint32, selections: [
            .all, .axis(0, [0..<2, 4..<9]), .axis(1, [0..<64, 128..<256]),
            .axis(1, [256..<320]), .axis(0, [8..<9]),
        ]),
        // Exact storage rank/geometry of the failing synthetic expert down
        // weight: interior-axis take used to leave a transposed U32 gather.
        SelectionFixture(name: "packed_expert", shape: [16, 128, 64], dtype: .uint32, selections: [
            .all, .axis(1, [0..<64]), .axis(2, [0..<32]), .axis(2, [32..<64]),
        ]),
        SelectionFixture(name: "expert_metadata", shape: [5, 8, 320], dtype: .bfloat16, selections: [
            .all, .axis(0, [0..<1, 3..<5]), .axis(1, [0..<2, 4..<8]),
            .axis(2, [0..<64, 128..<256]), .axis(2, [319..<320]),
            .axis(2, [0..<128, 128..<320]),
        ]),
        SelectionFixture(name: "conv_channels", shape: [20, 4, 1], dtype: .float16, selections: [
            .all, .axis(0, [0..<4, 8..<16, 18..<20]),
            .axis(1, [0..<1, 2..<4]), .axis(2, [0..<1]),
        ]),
    ]
}

private struct HeldSelection {
    let label: String
    let array: MLXArray
    let bytes: Data
}

private struct SelectionCheckRun {
    let arrays: [HeldSelection]
    let selections: Int
    let rejectedRanges: Int
    let comparedBytes: Int
}

private func checkOwnedSelection(_ array: MLXArray, label: String) throws {
    eval(array)
    guard let buffer = try array.evaluatedBufferInfo(), buffer.dataOffset == 0,
        buffer.isUnique, buffer.isRowContiguous, buffer.dataElements == array.size,
        buffer.allocatedBytes >= array.nbytes,
        buffer.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes))
    else { throw ProbeError("Selected tensor must own a bounded zero-offset contiguous buffer: \(label)") }
}

/// Keep descriptor lifetime separate from the final source-overwrite/delete check.
private func readSelectionFixture(directory: URL, configuration: Data, fixtures: [SelectionFixture]) throws
    -> SelectionCheckRun
{
    let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: configuration)
    let descriptors = try tensorDescriptors(checkpoint: checkpoint)
    guard Set(descriptors.keys) == Set(fixtures.map(\.name)),
        Set(descriptors.values.map { $0.file.path }) == ["weights-0.safetensors", "weights-1.safetensors"]
    else { throw ProbeError("Selection fixture did not span both verified tensor files") }
    var mlxSources: [String: MLXArray] = [:]
    for shard in 0..<2 {
        let loaded = try loadArrays(url: directory.appendingPathComponent("weights-\(shard).safetensors"))
        for (name, array) in loaded { mlxSources[name] = array }
    }
    var held: [HeldSelection] = []
    var rejected = 0, comparedBytes = 0, selections = 0
    for fixture in fixtures {
        guard let descriptor = descriptors[fixture.name], let source = mlxSources[fixture.name],
            descriptor.shape == fixture.shape, descriptor.dtype == fixture.dtype,
            descriptor.byteCount == fixture.bytes.count, source.asData().data == fixture.bytes
        else { throw ProbeError("Saved selection fixture differs from its CPU pattern") }
        for selection in fixture.selections {
            let label = fixture.name + ":" + selection.signature
            let expected = fixture.expected(selection)
            let read = try descriptor.read(selection)
            try checkOwnedSelection(read.array, label: label)
            guard read.array.shape == expected.shape, read.array.dtype == fixture.dtype,
                read.copiedBytes == expected.bytes.count, read.array.nbytes == expected.bytes.count,
                read.array.asData().data == expected.bytes
            else { throw ProbeError("Saved tensor selection differs from CPU coordinates: \(label)") }
            let oracle = try copySelectedTensor(source, selection: selection)
            // The original source remains alive in mlxSources during these
            // checks. Distinct object identity plus unique underlying storage
            // rejects both `return source` and MLX copy_shared_buffer aliases.
            try checkOwnedSelection(oracle, label: "in-memory:" + label)
            guard oracle !== source, oracle.shape == read.array.shape, oracle.dtype == read.array.dtype,
                oracle.asData().data == expected.bytes
            else { throw ProbeError("Saved tensor selection differs from materialized MLX oracle: \(label)") }
            comparedBytes += expected.bytes.count
            selections += 1
            held.append(HeldSelection(label: "file-read:" + label, array: read.array, bytes: expected.bytes))
            held.append(HeldSelection(label: "in-memory:" + label, array: oracle, bytes: expected.bytes))
        }
        let invalid: [TensorSelection] = [
            .axis(-1, [0..<1]), .axis(fixture.shape.count, [0..<1]), .axis(0, []),
            .axis(0, [1..<1]), .axis(0, [-1..<1]), .axis(0, [0..<(fixture.shape[0] + 1)]),
            .axis(0, [0..<3, 2..<4]), .axis(0, [2..<3, 0..<1]), .axis(0, [0..<1, 0..<1]),
        ]
        for selection in invalid {
            var failed = false
            do { _ = try descriptor.read(selection) } catch { failed = true }
            guard failed else { throw ProbeError("Saved tensor reader accepted invalid ranges") }
            rejected += 1
        }
    }
    try checkpoint.checkUnchanged()
    return SelectionCheckRun(arrays: held, selections: selections,
                             rejectedRanges: rejected, comparedBytes: comparedBytes)
}

func checkTensorSelections() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-selections-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configuration = Data("{\"fixture\":\"tensor-selections\"}".utf8)
    try configuration.write(to: directory.appendingPathComponent("config.json"))
    let fixtures = selectionFixtures()
    var index: [String: String] = [:]
    for shard in 0..<2 {
        let name = "weights-\(shard).safetensors"
        var arrays: [String: MLXArray] = [:]
        for (position, fixture) in fixtures.enumerated() where position % 2 == shard {
            arrays[fixture.name] = MLXArray(fixture.bytes, fixture.shape, dtype: fixture.dtype)
            index[fixture.name] = name
        }
        try save(arrays: arrays, url: directory.appendingPathComponent(name))
    }
    try JSONSerialization.data(withJSONObject: ["weight_map": index], options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    try writeFixtureManifest(directory)
    let checked = try readSelectionFixture(directory: directory, configuration: configuration, fixtures: fixtures)
    // All verified descriptors and ordinary MLX file loaders are now released.
    // In-place corruption detects accidental file-backed aliases before unlink.
    for shard in 0..<2 {
        let file = directory.appendingPathComponent("weights-\(shard).safetensors")
        let length = try Data(contentsOf: file).count
        let handle = try FileHandle(forWritingTo: file)
        do { try handle.write(contentsOf: Data(repeating: 0xCC, count: length)); try handle.close() }
        catch { try? handle.close(); throw error }
    }
    try FileManager.default.removeItem(at: directory)
    for held in checked.arrays {
        try checkOwnedSelection(held.array, label: held.label)
        guard held.array.asData().data == held.bytes else {
            throw ProbeError("Selected tensor changed after its source was overwritten/deleted: \(held.label)")
        }
    }
    struct Result: Encodable {
        let kind = "tensor_selection_parity"
        let tensorFiles = 2
        let tensorRanks = [1, 2, 3]
        let dtypes = ["uint32", "float32", "float16", "bfloat16"]
        let selections: Int
        let ownedInMemoryOracleCopies: Int
        let comparedBytes: Int
        let rejectedInvalidRanges: Int
        let independentCPUAndMLXOracles = true
        let uniqueZeroOffsetOwnedBuffers = true
        let inMemoryOraclesOwnDistinctSourceIndependentBuffers = true
        let inMemoryRank3RegressionCases = ["all", "axis1", "axis2"]
        let survivedSourceOverwriteAndDeletion = true
        let correctnessOnly = true
    }
    try emitJSON(Result(selections: checked.selections, ownedInMemoryOracleCopies: checked.selections,
                        comparedBytes: checked.comparedBytes,
                        rejectedInvalidRanges: checked.rejectedRanges))
}
