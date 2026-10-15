import Foundation

@main
struct ResidentBenchmarkWorkerProtocolCheckMain {
    static func main() throws {
        let result = try checkQwenResidentBenchmarkWorkerProtocol()
        var bytes = try canonicalJSONData(result)
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}
