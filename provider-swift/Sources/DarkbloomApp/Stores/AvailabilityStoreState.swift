import Foundation

enum AvailabilityFixture: String, CaseIterable, Sendable {
    case always
    case scheduledActive = "scheduled-active"
    case scheduledOff = "scheduled-off"
    case pausedScheduled = "paused-scheduled"
    case serving
    case loading
    case stale
    case malformed
    case saveFailure = "save-failure"
}

enum AvailabilityStoreLoadState: Equatable, Sendable {
    case loading
    case ready(lastUpdated: Date)
    case stale(lastUpdated: Date, message: String)
    case malformed(message: String, issues: [AvailabilityPolicySourceIssue])
}

enum AvailabilitySaveAndRestartState: Equatable, Sendable {
    case idle
    case saving
    case savedAndRestarted(at: Date)
    /// Live stores: the policy was written to the provider config, but the
    /// running daemon only parses its config at launch — nothing has applied
    /// yet. The view surfaces a restart banner (`AvailabilityStore.requiresRestart`).
    case savedRequiresRestart(at: Date)
    case validationFailed(issues: [AvailabilityPolicyValidationIssue])
    case failed(message: String)

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}
