import Foundation
import Darwin

struct RecordBenchmarkReport: Encodable {
    let schema = "darkbloom_authenticated_record_cpu_benchmark_v1"
    let clock = "DispatchTime.uptimeNanoseconds; same-process monotonic deltas"
    let timing = "seal/open include codec framing, locks, AEAD and Data staging; paired is sequential seal then open on this CPU"
    let excluded = "cohort key generation/HKDF and input/context preparation; output equality verification and caller-held output destruction after timing; all RDMA, network, MLX, GPU readback/upload, inference and coordinator authorization"
    let encryptedRDMAMeasured = false
    let modelMeasured = false
    let keysLogged = false
    let hostChip: String
    let cases: [RecordBenchmarkCase]
}

private func observedChip() throws -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
          size > 0, size <= 1024 else { throw RecordBenchmarkError.input }
    var bytes = [UInt8](repeating: 0, count: size)
    let result = bytes.withUnsafeMutableBufferPointer {
        sysctlbyname("machdep.cpu.brand_string", $0.baseAddress, &size, nil, 0)
    }
    guard result == 0 else { throw RecordBenchmarkError.input }
    let chip = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    guard ["Apple M4 Max", "Apple M4 Pro"].contains(chip) else { throw RecordBenchmarkError.input }
    return chip
}

@main
struct RecordBenchmarkMain {
    static func main() throws {
        guard CommandLine.arguments.count == 1 else { throw RecordBenchmarkError.input }
        let chip = try observedChip()
        let shapes = [("9b_prefill_bf16_c512", 4_194_304), ("27b_prefill_bf16_c512", 5_242_880),
                      ("9b_decode_bf16", 8_192), ("27b_decode_bf16", 10_240)]
        var cases = [RecordBenchmarkCase]()
        for (name, bytes) in shapes {
            for rank in [0, 1] {
                cases.append(try runRecordBenchmarkCase(name: name, bytes: bytes, sourceRank: rank,
                    warmups: 3, samples: 20))
            }
        }
        let report = RecordBenchmarkReport(hostChip: chip, cases: cases)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(report)
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([10]))
    }
}
