// Copyright © 2026 Eigen Labs.

import Foundation

/// The text a forced GPT-OSS call may show before the call: Harmony analysis
/// messages, which the stream's Harmony reasoning parser turns into
/// reasoning. The sampler admits nothing else (`GPTOSSForcedToolConstraint`);
/// this check keeps a forced response from exposing any other channel.
struct HarmonyForcedCallText {
    private static let header = "<|channel|>analysis<|message|>"
    private static let end = "<|end|>"

    private enum State {
        /// Between messages, holding a partial analysis header.
        case between(String)
        /// Inside an analysis body, holding a partial `<|end|>`.
        case analysis(String)
    }

    private var state = State.between("")

    /// The part of `text` to show, without whitespace between messages, or nil
    /// once the text leaves an analysis message.
    mutating func filter(_ text: String) -> String? {
        var shown = ""
        for character in text {
            switch state {
            case .between(var header):
                if header.isEmpty, character.isWhitespace { continue }
                header.append(character)
                guard Self.header.hasPrefix(header) else { return nil }
                state = header == Self.header ? .analysis("") : .between(header)
            case .analysis(var end):
                end.append(character)
                if end == Self.end {
                    state = .between("")
                } else {
                    while !end.isEmpty && !Self.end.hasPrefix(end) { end.removeFirst() }
                    state = .analysis(end)
                }
            }
            shown.append(character)
        }
        return shown
    }
}
