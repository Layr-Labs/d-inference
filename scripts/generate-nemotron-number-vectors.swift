// Run from the repository root. Captures the actual Swift Double spelling;
// Rust and Swift-Jinja consume the same oracle in their offline filter tests.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("coordinator/promptsidecar/src/render/json/swift_236_edges.json")
let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [[String: Any]]
var bits = Set(rows.compactMap { ($0["bits"] as? String).flatMap { UInt64($0, radix: 16) } })
for value: Double in [0, -0.0, 1, -1, 0.0001, 0.00001, 1e-6, 1e-7, 1e15, 1e16,
    1.25, -1.25, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude] {
    bits.insert(value.bitPattern)
}
print("{\"source\":\"Swift String(Double), finite bit patterns from swift_236_edges plus format boundaries\",\"vectors\":[")
for (index, bit) in bits.sorted().enumerated() {
    if index > 0 { print(",") }
    let value = Double(bitPattern: bit)
    precondition(value.isFinite)
    let row = ["bits": String(format: "%016llx", bit), "rendered": String(value)]
    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self), terminator: "")
}
print("\n]}")
