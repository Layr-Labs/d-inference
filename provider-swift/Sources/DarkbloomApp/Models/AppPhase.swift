import Foundation

enum AppPhase: String, CaseIterable, Codable, Identifiable, Sendable {
    case welcome
    case onboarding
    case product

    static let debugLaunchEnvironmentKey = "DARKBLOOM_LAUNCH_PHASE"

    var id: String { rawValue }

    static func debugLaunchOverride(
        environment: [String: String]
    ) -> AppPhase? {
        guard let value = environment[debugLaunchEnvironmentKey] else {
            return nil
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "welcome": return .welcome
        case "onboarding", "setup": return .onboarding
        case "product", "shell", "ready": return .product
        default: return nil
        }
    }

    static var currentDebugLaunchOverride: AppPhase? {
        #if DEBUG
        debugLaunchOverride(environment: ProcessInfo.processInfo.environment)
        #else
        nil
        #endif
    }
}
