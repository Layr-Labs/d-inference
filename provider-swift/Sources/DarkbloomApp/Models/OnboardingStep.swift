import Foundation

enum OnboardingStep: Int, CaseIterable, Codable, Identifiable, Sendable {
    case readiness
    case account
    case enrollment
    case preparation
    case verification
    case complete

    var id: Int { rawValue }

    var progressOrdinal: Int {
        switch self {
        case .readiness: 1
        case .account: 2
        case .enrollment, .preparation: 3
        case .verification, .complete: 4
        }
    }

    var resumeTitle: String {
        switch self {
        case .readiness: "Checking this Mac"
        case .account: "Connecting your account"
        case .enrollment: "Installing the verification profile"
        case .preparation: "Previewing optional model setup"
        case .verification: "Bringing this Mac online"
        case .complete: "Choosing what to do first"
        }
    }

    var eyebrow: String {
        switch self {
        case .readiness: "BEFORE WE BEGIN"
        case .account: "YOUR DARKBLOOM"
        case .enrollment: "VERIFY THIS MAC"
        case .preparation: "PRIVATE AI"
        case .verification: "TRUST CEREMONY"
        case .complete: "READY"
        }
    }

    var title: String {
        switch self {
        case .readiness: "Let’s check\nthis Mac."
        case .account: "Connect your\naccount."
        case .enrollment: "Verify\nthis Mac."
        case .preparation: "Previewing\nmodel setup."
        case .verification: "Bringing this\nMac online."
        case .complete: "This Mac\nis ready."
        }
    }

    var message: String {
        switch self {
        case .readiness:
            "Darkbloom will make sure this Mac can run private AI and join the network safely. Nothing changes during this check."
        case .account:
            "Link this Mac to your Darkbloom fleet with a short-lived browser code. Darkbloom requires this account link before network setup."
        case .enrollment:
            "Darkbloom uses a read-only management profile to verify this is a genuine, securely configured Mac."
        case .preparation:
            "This screen previews model setup only. Live setup will select a compatible model, confirm its exact size, and verify the finished download."
        case .verification:
            "Profile detection, enrollment check-in, and hardware trust are separate checks. Darkbloom will show exactly which one is still pending."
        case .complete:
            "This setup preview is complete. Live setup will reconcile the account, profile, hardware trust, and network before calling this Mac available. Models can be chosen later."
        }
    }

    var previous: OnboardingStep? {
        switch self {
        case .readiness: nil
        case .account: .readiness
        case .enrollment: .account
        case .preparation: .enrollment
        case .verification: .enrollment
        case .complete: nil
        }
    }

    init?(previewValue: String) {
        switch previewValue.lowercased() {
        case "check", "readiness": self = .readiness
        case "account", "link": self = .account
        case "enroll", "enrollment", "mdm", "profile": self = .enrollment
        case "prepare", "preparation", "download": self = .preparation
        case "verify", "verification", "online": self = .verification
        case "complete", "ready", "success": self = .complete
        default: return nil
        }
    }
}

enum OnboardingCompletionChoice: Equatable, Sendable {
    case startChat
    case reviewAvailability

    var destination: ProductDestination {
        switch self {
        case .startChat: .chat
        case .reviewAvailability: .availability
        }
    }
}
