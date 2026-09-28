import Foundation

struct CapabilityCheckFailure: Error { let message: String }
struct CapabilityCheckResults {
    var accepted: [String] = [], rejected: [String] = []
    mutating func yes(_ name: String, _ body: () throws -> Void) throws { try body(); accepted.append(name) }
    mutating func no(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw CapabilityCheckFailure(message: "Unexpected acceptance: " + name)
    }
}
func capabilityCheck(_ condition: Bool, _ message: String) throws {
    if !condition { throw CapabilityCheckFailure(message: message) }
}
