import Foundation

enum ProductDestination: String, CaseIterable, Codable, Identifiable, Sendable {
    case overview
    case chat
    case localAPI = "local-api"
    case myMacs = "my-macs"
    case contributions
    case availability
    case activity
    case models
    case machine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .chat: "Chat"
        case .localAPI: "Local API"
        case .myMacs: "My Macs"
        case .contributions: "Contributions"
        case .availability: "Availability"
        case .activity: "Activity"
        case .models: "Models"
        case .machine: "Hardware"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "sparkles"
        case .chat: "bubble.left.and.bubble.right"
        case .localAPI: "chevron.left.forwardslash.chevron.right"
        case .myMacs: "rectangle.3.group"
        case .contributions: "chart.line.uptrend.xyaxis"
        case .availability: "calendar.badge.clock"
        case .activity: "waveform.path.ecg"
        case .models: "shippingbox"
        case .machine: "desktopcomputer"
        }
    }

    var hidesProviderLifecycleControls: Bool {
        self == .localAPI || self == .myMacs || self == .availability
    }
}
