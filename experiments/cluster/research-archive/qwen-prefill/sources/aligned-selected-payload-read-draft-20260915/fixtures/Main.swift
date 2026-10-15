import Foundation
@main struct CheckMain {
 static func main() throws {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  FileHandle.standardOutput.write(try encoder.encode(checkAlignedCheckpointPayloadRead()) + Data([10]))
 }
}
