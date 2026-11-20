import Foundation

@main struct GenerationPairControlMain {
    static func main() throws {
        FileHandle.standardOutput.write(try canonicalJSONData(checkGenerationPairControl()) + Data([10]))
    }
}
