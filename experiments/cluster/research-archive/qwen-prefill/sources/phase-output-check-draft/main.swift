import Foundation
import Darwin

do {
    let result = try checkQwenPrefillPhaseOutput()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(result); data.append(10)
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data("phase-output-check: \(error)\n".utf8))
    exit(1)
}
