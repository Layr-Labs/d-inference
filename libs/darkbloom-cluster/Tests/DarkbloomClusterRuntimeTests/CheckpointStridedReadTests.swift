import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// A rank's runs of a tensor divided on an inner axis are read together where they share pages, with the same
// bytes. CPU fixture, no model. The same check runs in `Tests/CheckpointChecks/run.sh`.

@Suite("Checkpoint runs that share pages are read together (CPU fixture)")
struct CheckpointStridedReadTests {
    @Test func runsThatSharePagesAreReadTogether() throws {
        try CheckpointStridedReadCheck.run()
    }

    /// Through `TensorDescriptor.read`, uncached: each rank's half of a tensor shaped like MiMo's expert `down_proj`
    /// (`U32 [2, 4096, 256]`, ending the file off a page) and of an odd-sized `BF16` tensor at an offset off a page is
    /// byte-identical to one aligned read per run, as before the change. Whole-axis and several-range selections still
    /// take one read per run.
    @Test func dividedAxisReadsMatchOneReadPerRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-strided-tensor-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let pad = 12, odd = 5 * 6 * 7 * 2, down = 2 * 4096 * 256 * 4
        let header = try JSONSerialization.data(withJSONObject: [
            "pad": ["dtype": "F32", "shape": [3], "data_offsets": [0, pad]],
            "odd": ["dtype": "BF16", "shape": [5, 6, 7], "data_offsets": [pad, pad + odd]],
            "down": ["dtype": "U32", "shape": [2, 4096, 256], "data_offsets": [pad + odd, pad + odd + down]],
        ], options: [.sortedKeys])
        var length = UInt64(header.count).littleEndian
        var file = Data(bytes: &length, count: 8)
        file.append(header)
        file.append(CheckpointStridedReadCheck.seeded(pad + odd + down, seed: 3))
        #expect(file.count % CheckpointAlignedReadPlan.alignmentBytes != 0)
        let checkpoint = try CheckpointStridedReadCheck.fixture(root: root, files: ["model-00001-of-00001.safetensors": file])
        try checkpoint.bypassTensorPayloadCache()
        let descriptors = try tensorDescriptors(checkpoint: checkpoint)

        func onePerRun(_ tensor: TensorDescriptor, axis: Int, ranges: [Range<Int>]) throws -> (Data, Int) {
            let inner = tensor.shape.dropFirst(axis + 1).reduce(tensor.dtype.size, *)
            let stride = tensor.shape[axis] * inner
            var bytes = Data(), calls = 0
            for outer in 0..<tensor.shape.prefix(axis).reduce(1, *) {
                for range in ranges {
                    var run = Data(count: range.count * inner)
                    let accounting = try run.withUnsafeMutableBytes {
                        try tensor.file.read(into: $0, offset: tensor.offset + outer * stride + range.lowerBound * inner)
                    }
                    calls += try #require(accounting).preadCalls
                    bytes.append(run)
                }
            }
            return (bytes, calls)
        }
        func check(_ name: String, axis: Int, ranges: [Range<Int>], together: Bool) throws {
            let tensor = try #require(descriptors[name])
            let read = try tensor.read(.axis(axis, ranges))
            eval(read.array)
            let (expected, calls) = try onePerRun(tensor, axis: axis, ranges: ranges)
            #expect(read.array.asData(access: .copy).data == expected, "\(name) \(ranges)")
            let accounting = try #require(read.readAccounting)
            #expect(accounting.selectedBytes == expected.count)
            #expect(together ? accounting.preadCalls < calls : accounting.preadCalls == calls, "\(name) \(ranges)")
        }
        for rank in 0..<2 {
            try check("down", axis: 2, ranges: [rank * 128 ..< (rank + 1) * 128], together: true)
            try check("odd", axis: 1, ranges: [rank * 3 ..< (rank + 1) * 3], together: true)
        }
        try check("odd", axis: 2, ranges: [6 ..< 7], together: true)
        try check("down", axis: 2, ranges: [0 ..< 256], together: false)
        try check("odd", axis: 1, ranges: [0 ..< 1, 4 ..< 6], together: false)
    }
}
