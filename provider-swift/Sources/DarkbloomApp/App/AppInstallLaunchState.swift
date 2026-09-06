import Foundation

enum AppInstallLaunchState {
    case ready
    case handingOff
    case relaunchRequired(AppInstallationRecovery)
    case failed(AppInstallationFailure)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isInteractive: Bool {
        switch self {
        case .ready, .relaunchRequired, .failed:
            true
        case .handingOff:
            false
        }
    }
}

struct AppInstallationFailure {
    let message: String
    let recoverySuggestion: String
    let destination: URL

    init(error: any Error, destination: URL) {
        let localized = error as? any LocalizedError
        message = localized?.errorDescription
            ?? (error as NSError).localizedDescription
        recoverySuggestion = localized?.recoverySuggestion
            ?? "Check that ~/.darkbloom and your home Applications folder are writable, then reopen Darkbloom."
        self.destination = destination
    }
}
