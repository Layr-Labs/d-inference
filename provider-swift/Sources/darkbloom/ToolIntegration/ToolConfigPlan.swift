import Foundation

/// What a planner decided for one tool's config file. Planners are pure: the file's bytes in, the new bytes out.
enum ToolConfigPlan: Equatable, Sendable {
    /// The file already says exactly this, so nothing is written and no backup is made.
    case unchanged(ToolConfigSummary)
    /// The whole file's new bytes.
    case change(Data, ToolConfigSummary)
    /// Nothing may be written.
    case refused(ToolConfigRefusal)
}

/// What an edit does to a tool's config, for the lines `start` prints.
struct ToolConfigSummary: Equatable, Sendable {
    enum ProviderChange: Equatable, Sendable {
        case added
        case updated
        case unchanged
    }

    var provider: ProviderChange
    /// The model IDs the tool's config lists for Darkbloom, in their order.
    var models: [String]
    /// The tool's default model as this edit sets it; nil when the edit leaves the default alone.
    var defaultModel: String?
    /// The default model the edit leaves alone, as the tool's config names it (OpenCode: the `model` a global config
    /// file sets, `exo/llama-3.3-70b`); nil when the edit sets one, or the config's default has no name.
    var keptDefault: String?
    /// The main model this edit replaced, in the tool's words (Hermes: `gpt-6-astra via opencodex`); nil when there
    /// was none, or it was Darkbloom's already.
    var replacedDefault: String?
    /// The endpoint's models the tool can't use, left out of its config (Hermes: under 64K context).
    var leftOut: [String] = []
    /// Comments on the lines the edit replaced or removed. The backup keeps them.
    var droppedComments = 0
    /// The models the config now lists with fallbacks for what the catalog would say (offline, or a model it doesn't
    /// list), the file having no entry of its own for them: their names and image input are guesses.
    var undescribed: [String] = []

    /// The plain-words line about lost comments, or nil when every comment survived.
    var droppedCommentsNote: String? {
        switch droppedComments {
        case 0: nil
        case 1: "1 comment on the lines Darkbloom replaced is gone; the backup keeps it."
        default: "\(droppedComments) comments on the lines Darkbloom replaced are gone; the backup keeps them."
        }
    }
}

/// Why nothing was written, in plain words.
struct ToolConfigRefusal: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The file: it isn't valid, uses a construct Darkbloom doesn't edit, or changed during the edit.
        case file
        /// Darkbloom's models: none of them suits the tool.
        case models
    }

    let kind: Kind
    /// For `.file`, a clause that follows "Didn't change <file>: "; for `.models`, whole sentences.
    let reason: String

    static func file(_ reason: String) -> ToolConfigRefusal { ToolConfigRefusal(kind: .file, reason: reason) }
    static func models(_ reason: String) -> ToolConfigRefusal { ToolConfigRefusal(kind: .models, reason: reason) }

    /// The whole refusal line, without its `✗` mark.
    func message(file: String) -> String {
        switch kind {
        case .file: "Didn't change \(file): \(reason)."
        case .models: reason
        }
    }
}
