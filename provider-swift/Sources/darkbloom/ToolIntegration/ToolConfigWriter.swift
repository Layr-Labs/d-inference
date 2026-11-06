import Darwin
import Foundation
import ProviderCore

/// Makes a planned edit to a tool's config safely.
struct ToolConfigWriter {
    enum Outcome: Equatable, Sendable {
        case unchanged(file: URL, ToolConfigSummary)
        case planned(file: URL, contents: Data, ToolConfigSummary)
        case written(file: URL, backup: URL?, undo: String, ToolConfigSummary)
        case refused(file: URL, ToolConfigRefusal)
    }

    let tool: IntegrationTool
    let stateDirectory: URL
    var keptBackups = 5
    var now: @Sendable () -> Date = { Date() }
    var beforeReplace: (URL) throws -> Void = { _ in }

    func apply(
        to file: URL, newFileMode: mode_t, dryRun: Bool = false, plan: (Data?) -> ToolConfigPlan
    ) throws -> Outcome {
        .refused(file: file, .file("not built yet"))
    }
}
