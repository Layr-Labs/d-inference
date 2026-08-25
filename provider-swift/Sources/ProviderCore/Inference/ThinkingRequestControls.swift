import Foundation

/// Per-request thinking controls for the **local HTTP** path.
///
/// Coordinator-bound requests construct a fresh `MultiModelBatchSchedulerEngine`
/// with explicit `reasoningEffort` / `enableThinkingOverride`. The shared
/// `--local` engine cannot carry those as constructor state, so
/// `LocalChatUploadResponder` binds them on the task before entering the
/// service (issue #639 / Codex review on PR #677).
struct ThinkingRequestControls: Sendable {
    var reasoningEffort: String?
    var enableThinkingOverride: Bool?

    @TaskLocal static var current: ThinkingRequestControls?
}
