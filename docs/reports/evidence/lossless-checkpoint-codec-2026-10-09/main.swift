import Foundation
import CryptoKit

enum SSDBlockStoreError: Error { case malformedHeader(String), sizeOverflow(String) }
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: input)
var chunks: [Data] = []
for offset in stride(from: 0, to: data.count, by: 4 << 20) {
    chunks.append(data.subdata(in: offset..<min(data.count, offset + (4 << 20))))
}
var encoded = 0
var encodeTimes: [Double] = []
var decodeTimes: [Double] = []
for _ in 0..<5 {
    let start = ContinuousClock.now
    let frames = try chunks.map { try SSDLosslessChunkCodec.encode($0, elementBytes: 2) }
    let encodeTime = start.duration(to: .now)
    let decodeStart = ContinuousClock.now
    let restored = try frames.enumerated().map { try SSDLosslessChunkCodec.decode($0.element, nativeBytes: chunks[$0.offset].count) }
    let decodeTime = decodeStart.duration(to: .now)
    precondition(restored == chunks)
    encoded = frames.reduce(0) { $0 + $1.count }
    func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds)/1e18 }
    encodeTimes.append(seconds(encodeTime)); decodeTimes.append(seconds(decodeTime))
}
let result: [String: Any] = ["schema":"darkbloom.production-lossless-codec-benchmark.v1", "input": input.lastPathComponent,
    "inputSHA256":sha(data), "nativeBytes":data.count, "encodedFrameBytes":encoded,
    "savingFraction":1-Double(encoded)/Double(data.count), "encodeSeconds":encodeTimes,
    "decodeSeconds":decodeTimes, "bitExact":true, "scope":"actual production codec source compiled -O; public Qwen BF16 owner0 packet; no encryption, disk IO, device readback or whole-model performance claim"]
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
print(String(decoding:json,as:UTF8.self))
