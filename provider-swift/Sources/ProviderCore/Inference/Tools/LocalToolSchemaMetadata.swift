// Copyright © 2026 Eigen Labs.

import Foundation

/// Testing switch: lets the local API (`darkbloom start --local`) take tool
/// schemas that carry the ingress repair's render marker
/// (`ToolSchemaNormalization.originalBooleanSchemaKey`), as the coordinator
/// forwards them, so a loopback run can serve the shapes production sees.
/// Off by default: the local API refuses such schemas from clients.
///
/// `DARKBLOOM_LOCAL_ALLOW_TOOL_SCHEMA_METADATA`: exactly `1` turns it on; any
/// other value, or none, keeps it off. Read once per process; a warning line
/// is logged when it is on. The coordinator path accepts the marker already.
enum LocalToolSchemaMetadata {
    static let environmentKey = "DARKBLOOM_LOCAL_ALLOW_TOOL_SCHEMA_METADATA"

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "local-tool-schema-metadata")

    static func allowed(environment: [String: String]) -> Bool {
        environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// The process's setting, logged once when it is on.
    static let current: Bool = {
        let on = allowed(environment: ProcessInfo.processInfo.environment)
        if on {
            logger.warning(
                "\(environmentKey)=1: the local API accepts tool schemas with render markers (testing switch)")
        }
        return on
    }()
}
