import Foundation
import CryptoKit
struct ProbeError: Error { let description: String; init(_ text: String) { description = text } }
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
 let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
}
@main enum CheckMain {
 static func main() throws {
  let data = try BoundedProbeInput.data(URL(fileURLWithPath: CommandLine.arguments[1]), maximumBytes: 1048576)
  let result = try checkQwenLongPrefillReferenceAdmission(configuration: data)
  print("accepted=\(result.accepted) rejected=\(result.rejected)")
 }
}
