import Foundation

struct LocalChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let isPreview: Bool
    let modelID: String?
    var interruption: Interruption?

    enum Interruption: Equatable, Sendable {
        case stopped
        case failed
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isPreview: Bool = false,
        modelID: String? = nil,
        interruption: Interruption? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isPreview = isPreview
        self.modelID = modelID
        self.interruption = interruption
    }
}

enum ChatRoute: String, CaseIterable, Identifiable, Sendable {
    case thisMac
    case privateNetwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMac: "This Mac"
        case .privateNetwork: "Private network"
        }
    }

    var systemImage: String {
        switch self {
        case .thisMac: "desktopcomputer"
        case .privateNetwork: "point.3.connected.trianglepath.dotted"
        }
    }

    var previewNote: String {
        switch self {
        case .thisMac: "Local chat UI · no model is running"
        case .privateNetwork: "Network chat UI · nothing is routed"
        }
    }
}
