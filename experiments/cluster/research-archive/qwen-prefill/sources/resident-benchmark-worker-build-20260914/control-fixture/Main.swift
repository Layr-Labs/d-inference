import Foundation

@main
struct ControlFixtureMain {
    static func main() throws {
        let result = try checkResidentBenchmarkWorkerControl()
        var bytes = try canonicalJSONData(result); bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}
