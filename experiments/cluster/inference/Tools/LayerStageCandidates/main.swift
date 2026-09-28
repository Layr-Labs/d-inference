import Foundation
import Darwin

do {
    let options = try QwenCandidateExportCLI(arguments: Array(CommandLine.arguments.dropFirst()))
    let record = try options.encoded()
    try FileHandle.standardOutput.write(contentsOf: record)
} catch {
    FileHandle.standardError.write(Data("candidate-export: \(error)\n".utf8))
    exit(1)
}
