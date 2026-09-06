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
        case .enrollment: 3
        case .preparation: 4
        case .verification, .complete: 5
        }
    }

    var resumeTitle: String {
        switch self {
        case .readiness: "Checking this Mac"
        case .account: "Connecting your account"
        case .enrollment: "Installing the verification profile"
        case .preparation: "Preparing a private model"
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
        case .verification: "FINAL CHECK"
        case .complete: "READY"
        }
    }

    var title: String {
        switch self {
        case .readiness: "Let’s check\nthis Mac."
        case .account: "Connect your\naccount."
        case .enrollment: "Verify\nthis Mac."
        case .preparation: "Choose your\nprivate model."
        case .verification: "Bringing this\nMac online."
        case .complete: "This Mac\nis ready."
        }
    }

    var message: String {
        switch self {
        case .readiness:
            "Darkbloom will make sure this Mac can run private AI and join the network safely. Nothing changes during this check."
        case .account:
            "Sign in through your browser to keep your Macs and earnings together. Return here when you’ve approved this Mac."
        case .enrollment:
            "Darkbloom uses a read-only management profile to verify this is a genuine, securely configured Mac."
        case .preparation:
            "Choose a model that fits this Mac. Darkbloom handles the download and checks it before starting your local AI engine."
        case .verification:
            "We’re confirming this Mac is ready to connect. You’ll see each check as it completes."
        case .complete:
            "Your account, verification profile, private model, local API, and hardware trust are ready."
        }
    }

    var previous: OnboardingStep? {
        switch self {
        case .readiness: nil
        case .account: .readiness
        case .enrollment: .account
        case .preparation: .enrollment
        case .verification: .preparation
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
