// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// How Muse Glimmer's tool channels become calls.
///
/// On by default, the reference servers' reading (`ATEMReferenceReader`):
/// every complete invoke is a call, typed as vLLM types it (a string
/// parameter keeps its text, a local `$ref` is resolved, `6.0` is an integer
/// where only an integer is admitted). The call then meets the request's own
/// rules (`ToolConstraintValidation`): `auto` without `strict` returns it as
/// generated, an undeclared name or arguments off the schema included, as
/// vLLM does; a `strict` tool or a forced choice holds it to the declarations
/// and refuses it as the model's noncompliance (422).
///
/// `DARKBLOOM_MUSE_GLIMMER_REFERENCE_TOOL_CALLS`: `0`, `off` or `false`
/// restores the SDK's strict parser (`ATEMToolCallParser`), which rejects
/// those calls. Either way an invalid tool frame is the model's
/// noncompliance (422), never a provider failure (500).
enum MuseGlimmerToolCallReading {
    static let environmentKey = "DARKBLOOM_MUSE_GLIMMER_REFERENCE_TOOL_CALLS"

    static let current = enabled(environment: ProcessInfo.processInfo.environment)

    static func enabled(environment: [String: String]) -> Bool {
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["0", "off", "false"].contains(raw ?? "")
    }
}
