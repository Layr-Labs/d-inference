import Foundation

/// Actor-owned admission fences. Accepted work must not wait on this fence:
/// it owns the old engine until the separate, idle publication boundary.
struct MTPAdmissionDrains {
    private var owners: [String: UUID] = [:]
    private(set) var generation: UInt64 = 0

    func contains(_ modelID: String) -> Bool { owners[modelID] != nil }

    @discardableResult
    mutating func begin(_ modelID: String, owner: UUID) -> Bool {
        if let current = owners[modelID] { return current == owner }
        owners[modelID] = owner
        generation &+= 1
        return true
    }

    @discardableResult
    mutating func end(_ modelID: String, owner: UUID) -> Bool {
        guard owners[modelID] == owner else { return false }
        owners.removeValue(forKey: modelID)
        generation &+= 1
        return true
    }
}
