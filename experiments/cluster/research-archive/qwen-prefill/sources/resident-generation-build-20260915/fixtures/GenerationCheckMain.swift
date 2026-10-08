import Foundation

@main struct GenerationCheckMain {
    static func main() throws {
        let result = try checkQwenLayerStageGeneration()
        FileHandle.standardOutput.write(try canonicalJSONData(result) + Data([10]))
    }
}
