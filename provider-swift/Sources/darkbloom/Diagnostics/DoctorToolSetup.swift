import Foundation
import ProviderCore

// Seam for the red tests of `darkbloom doctor`'s tool lines, with today's behaviour: doctor reads no tool's config.

struct DoctorToolSetup: Equatable, Sendable {
    enum Found: Equatable, Sendable {
        case noFile
        case noEntry
        case entry(address: String, keyFile: String?)
        case unreadable(String)
    }

    let tool: IntegrationTool
    let file: URL
    let found: Found

    static func read(_ environment: ToolIntegrationEnvironment = .current,
                     provider: IntegrationProvider = .current) -> [DoctorToolSetup] { [] }

    static func expanded(_ path: String, home: URL) -> String { path }

    static func sameAddress(_ one: String, _ other: String) -> Bool { one == other }
}
