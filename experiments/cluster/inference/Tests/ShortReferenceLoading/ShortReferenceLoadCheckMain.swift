import Foundation

@main struct ShortReferenceLoadCheckMain {
    static func main() throws {
        let data = FileHandle.standardInput.readData(ofLength: 4 * 1024 * 1024 + 1)
        guard (1...(4 * 1024 * 1024)).contains(data.count) else {
            throw ProbeError("Short reference fixture input exceeds its bound")
        }
        let inputs = try JSONDecoder().decode(QwenObservedFixtureInputs.self, from: data)
        let result = try checkQwenDenseShortReferenceLoading(inputs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
