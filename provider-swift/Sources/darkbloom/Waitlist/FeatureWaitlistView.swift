import Foundation

/// The lines that tell an account where it stands on a feature's waitlist.
struct FeatureWaitlistView: Sendable {
    let feature: FeatureWaitlistFeature
    /// The installed command, `darkbloom` or the DevNet `darkbloom-dev`.
    let cli: String
    /// The coordinator asked, for the problems that name it.
    let coordinator: String
    var day: @Sendable (Date) -> String = FeatureWaitlistView.mediumDate

    /// What the feature's command group calls it: `cluster` or `sandbox`.
    private var group: String { "\(cli) \(feature.rawValue)" }

    /// The command that starts using the feature once the account is
    /// approved.
    private var start: String {
        switch feature {
        case .cluster: "\(cli) cluster"
        case .sandbox: "\(cli) sandbox setup"
        }
    }

    /// The account's place, after `waitlist`, `waitlist status` or
    /// `waitlist join`.
    func lines(_ place: FeatureWaitlistPlace) -> [String] {
        switch place.status {
        case .none:
            return [
                "You're not on the \(feature.waitlistName).",
                "  Join it: \(group) waitlist join",
            ]
        case .waitlisted:
            var line = "You're on the \(feature.waitlistName)"
            if let position = place.position { line += ": #\(position) in line" }
            if let requestedAt = place.requestedAt { line += " (joined \(day(requestedAt)))" }
            return [
                line + ".",
                "  Darkbloom reviews accounts in the order they joined and approves them by hand.",
                "  Check again: \(group) waitlist",
            ]
        case .approved:
            let since = place.decidedAt.map { " since \(day($0))" } ?? ""
            return [
                "Your account is approved for \(feature.title)\(since).",
                "  Start: \(start)",
            ]
        case .revoked:
            let since = place.decidedAt.map { " on \(day($0))" } ?? ""
            return [
                "Darkbloom revoked your account's access to \(feature.title)\(since).",
                "  Joining again does not restore it; contact Darkbloom if you think this is a mistake.",
            ]
        }
    }

    /// Why a waitlist call has no place to show.
    func problem(_ lookup: FeatureWaitlistLookup) -> [String] {
        switch lookup {
        case .place:
            return []
        case .notOffered:
            return ["\(coordinator) has no waitlists yet, so there is nothing to join there."]
        case .needsLogin:
            return ["Link this Mac to your Darkbloom account first: \(cli) login"]
        case .unavailable(let reason):
            return ["Could not reach the \(feature.waitlistName) at \(coordinator): \(reason)"]
        }
    }

    @Sendable static func mediumDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
