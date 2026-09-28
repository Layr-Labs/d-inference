import Foundation
import Darwin

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(value)
    data.append(10)
    FileHandle.standardOutput.write(data)
}

do {
    try emit(checkCBv2OwnerPhaseObservation())
    try emit(checkQwenPrefillPhaseRecorder())
    try emit(checkQwenPrefillPhaseOutput())
    try emit(checkQwenPrefillOwnerRecorder())
    try emit(checkQwenPrefillOwnerOutput())
} catch {
    FileHandle.standardError.write(Data("phase-tracing-check: \(error)\n".utf8))
    exit(1)
}
