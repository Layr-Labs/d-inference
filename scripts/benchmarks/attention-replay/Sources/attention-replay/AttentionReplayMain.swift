import Foundation
@_spi(Benchmarking) import MLXLMCommon

struct ReplayReceipt: Encodable {
    let schema = "darkbloom.attention-replay-result.v1"
    let inputSHA256, arm, dispatch, kernelOutputDType: String
    let offset, segmentCount: Int
    let pageTable: [Int32]
    let partitionTokens: Int?
    let partitionGeometrySource = "Pinned pure sizer applied to actual replay geometry; dispatch observed at call site"
    let geometry: ReplayGeometry
    let tensors: [String: ReplayTensorDescriptor]
}

@main
struct AttentionReplayMain {
    static func main() throws {
        let options = try ReplayOptions(Array(CommandLine.arguments.dropFirst()))
        guard let arm = CBv2AttentionReplay.Arm(rawValue: options.arm) else {
            throw ReplayFailure.invalidInput("unsupported replay arm")
        }
        let (_, input) = try ReplayTransfer.load(options)
        try require(!FileManager.default.fileExists(atPath: options.output.path), "output already exists")
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: false)
        let result = try CBv2AttentionReplay.run(input, arm: arm)
        var tensors = ["output": result.output]
        if let keys = result.storedKeys { tensors["storedKeys"] = keys }
        if let values = result.storedValues { tensors["storedValues"] = values }
        var descriptors = [String: ReplayTensorDescriptor]()
        for (name, tensor) in tensors {
            let file = name + ".bin"
            try tensor.bytes.write(to: options.output.appendingPathComponent(file), options: .withoutOverwriting)
            var strides = [Int](repeating: 0, count: tensor.shape.count), count = 1
            for i in tensor.shape.indices.reversed() { strides[i] = count; count *= tensor.shape[i] }
            descriptors[name] = ReplayTensorDescriptor(file: file, dtype: String(describing: tensor.dtype),
                byteOrder: "little", sha256: sha256(tensor.bytes), shape: tensor.shape,
                packedStrides: strides, byteCount: tensor.bytes.count)
        }
        try writeJSON(ReplayReceipt(inputSHA256: options.inputSHA256, arm: arm.rawValue,
            dispatch: result.dispatch, kernelOutputDType: result.kernelOutputDType, offset: result.offset,
            segmentCount: result.segmentCount, pageTable: result.pageTable, partitionTokens: result.partitionTokens,
            geometry: ReplayGeometry(result.geometry), tensors: descriptors),
            to: options.output.appendingPathComponent("result.json"))
    }
}
