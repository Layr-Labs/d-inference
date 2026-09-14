import Foundation
import SandboxRuntime

enum AccountlessImageOpeners {
    struct Entry: Hashable { let pid: Int32; let descriptor: String }

    static func requireOnlyRetainedDescriptor(_ result: SandboxProcessResult, pid: Int32, descriptor: Int32) throws {
        guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated,
              result.standardError.isEmpty, let text = String(data: result.standardOutput, encoding: .utf8) else {
            throw AccountlessDiskError.cleanupUnproven
        }
        var currentPID: Int32?, entries = Set<Entry>()
        for row in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let value = row.dropFirst()
            switch row.first {
            case "p":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int32(value), parsed > 0 else { throw AccountlessDiskError.invalidInventory }
                currentPID = parsed
            case "f":
                guard let currentPID, !value.isEmpty, value.utf8.count <= 32,
                      value.utf8.allSatisfy({ (33...126).contains($0) }),
                      entries.insert(.init(pid: currentPID, descriptor: String(value))).inserted else {
                    throw AccountlessDiskError.invalidInventory
                }
            default: throw AccountlessDiskError.invalidInventory
            }
        }
        guard entries == [.init(pid: pid, descriptor: String(descriptor))] else {
            throw AccountlessDiskError.cleanupUnproven
        }
    }
}
