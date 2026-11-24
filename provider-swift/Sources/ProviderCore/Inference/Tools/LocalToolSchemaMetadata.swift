// Copyright © 2026 Eigen Labs.

/// Red control: the testing switch is declared but never on.
enum LocalToolSchemaMetadata {
    static let environmentKey = "DARKBLOOM_LOCAL_ALLOW_TOOL_SCHEMA_METADATA"

    static func allowed(environment: [String: String]) -> Bool { false }
}
