// The engine's admission order for a request the provider submits: what an exit-thinking continuation raises.

import Foundation

/// The engine's admission priority (`CBv2Request.priority`: its waiting queue admits higher first, then in arrival
/// order) for a request submitted inside it; `EngineV2Bridge.submitTokenized` reads it. Every request has 0 but the
/// continuation that answers a thought the loop guard ended (`LoopExitThinkingContinuation.admissionPriority`). That
/// continuation takes its stopped row's place. Behind the requests already waiting for a slot, it would wait past
/// the engine's admission lease (120 s) and end `admission_timeout` with no answer.
enum EngineAdmissionPriority {
    @TaskLocal static var current = 0
}
