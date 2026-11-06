import Foundation

@main
struct PhaseClockFoundationHarness {
    static func main() throws {
        let result = try checkQwenPrefillPhaseRecorder()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
