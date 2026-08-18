import Foundation

enum ProviderAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case start
    case stop
    case restart
    case refresh
    case runDiagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Pause"
        case .restart: "Restart"
        case .refresh: "Refresh Status"
        case .runDiagnostics: "Run Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "pause.fill"
        case .restart: "arrow.clockwise"
        case .refresh: "arrow.triangle.2.circlepath"
        case .runDiagnostics: "stethoscope"
        }
    }

    var changesRuntime: Bool {
        switch self {
        case .start, .stop, .restart: true
        case .refresh, .runDiagnostics: false
        }
    }
}
