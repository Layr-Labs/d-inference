import Foundation
import Darwin

do {
    let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
    guard !data.isEmpty, data.count <= 1_048_576 else { throw ProbeError("Candidate export fixture stdin exceeds 1 MiB") }
    let inputs = try JSONDecoder().decode(CandidateExportRetainedInputs.self, from: data)
    let result = try checkCandidateExport(inputs)
    try FileHandle.standardOutput.write(contentsOf: QwenCandidateExportEncoding.record(result))
} catch {
    FileHandle.standardError.write(Data("candidate-export-check: \(error)\n".utf8))
    exit(1)
}
