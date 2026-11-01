import Foundation

/// Retains actual failed owners and their activity leases. No timeout, flag or
/// disappearance of a caller can authorize a memory refund after a failed join.
///
/// Owners outside any published slot may still hold weights and KV. Their
/// charged bytes are subtracted from fleet KV budgets so survivors and other
/// families can never be granted memory a retained GLM owner may occupy.
final class GLM5NextRetainedOwnerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [AnyObject] = []
    // Keys are retained in `owners` for the process lifetime, so an
    // ObjectIdentifier can never be reused for a different object.
    private var charges: [ObjectIdentifier: UInt64] = [:]

    var isRetained: Bool { lock.withLock { !owners.isEmpty } }
    var retainedOwnerObjectCount: Int { lock.withLock { owners.count } }
    var retainedResidentBytes: UInt64 {
        lock.withLock { GLM5NextLoadFaultState.saturatingSum(charges.values) }
    }

    var diagnosticMetrics: String {
        "# HELP darkbloom_glm5_next_retained_fault 1 after an unproven GLM native retirement; GLM work is refused until restart.\n"
            + "# TYPE darkbloom_glm5_next_retained_fault gauge\n"
            + "darkbloom_glm5_next_retained_fault \(isRetained ? 1 : 0)\n"
            + "# HELP darkbloom_glm5_next_retained_owner_objects Distinct in-process objects kept alive by GLM faults (bridges, containers, leases); not a model count.\n"
            + "# TYPE darkbloom_glm5_next_retained_owner_objects gauge\n"
            + "darkbloom_glm5_next_retained_owner_objects \(retainedOwnerObjectCount)\n"
            + "# HELP darkbloom_glm5_next_retained_resident_bytes Unpublished weight and KV bytes charged to retained GLM owners and excluded from fleet KV grants.\n"
            + "# TYPE darkbloom_glm5_next_retained_resident_bytes gauge\n"
            + "darkbloom_glm5_next_retained_resident_bytes \(retainedResidentBytes)\n"
    }

    func requireHealthy(modelType: String?) throws {
        if GLM5NextPromptPolicy.applies(modelType: modelType) { try requireHealthy() }
    }

    func requireHealthy() throws {
        guard !isRetained else { throw GLM5NextManagedLoadError.retirementUnproven }
    }

    func retain(_ values: [AnyObject]) {
        lock.withLock { appendOwners(values) }
    }

    /// Charges memory held by `key` outside every published slot. Nested
    /// failure paths may charge the same key; the larger figure wins so the
    /// same weights are never counted twice.
    func retain(_ values: [AnyObject], charging key: AnyObject, residentBytes: UInt64) {
        lock.withLock {
            appendOwners(values + [key])
            let id = ObjectIdentifier(key)
            charges[id] = max(charges[id] ?? 0, residentBytes)
        }
    }

    private func appendOwners(_ values: [AnyObject]) {
        for value in values where !owners.contains(where: { $0 === value }) {
            owners.append(value)
        }
    }
}

enum GLM5NextLoadFaultState {
    private static let store = GLM5NextRetainedOwnerStore()
    static var isRetained: Bool { store.isRetained }
    static var retainedResidentBytes: UInt64 { store.retainedResidentBytes }
    static var diagnosticMetrics: String { store.diagnosticMetrics }
    static func requireHealthy() throws { try store.requireHealthy() }
    static func requireHealthy(modelType: String?) throws { try store.requireHealthy(modelType: modelType) }
    static func retain(_ values: [AnyObject]) { store.retain(values) }
    static func retain(_ values: [AnyObject], charging key: AnyObject, residentBytes: UInt64) {
        store.retain(values, charging: key, residentBytes: residentBytes)
    }

    /// Fleet KV arithmetic input: published slot weights plus this charge.
    static func addingRetainedResidentBytes(to bytes: UInt64) -> UInt64 {
        saturatingSum([bytes, retainedResidentBytes])
    }

    /// Saturating weight + KV charge; negative components count as zero.
    static func residentBytes(_ parts: Int...) -> UInt64 {
        saturatingSum(parts.map { UInt64(max(0, $0)) })
    }

    static func saturatingSum(_ values: some Sequence<UInt64>) -> UInt64 {
        values.reduce(UInt64(0)) { total, value in
            let sum = total.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }
}
