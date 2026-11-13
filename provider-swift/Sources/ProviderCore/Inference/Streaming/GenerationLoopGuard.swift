// Copyright © 2026 Eigen Labs.

import Foundation

/// One row's loop guard. The detector watches the row's generated tokens; the
/// guard is off for the rest of the row once its text shows a tool-call frame,
/// so a call's arguments (a file of repeated lines, say) are never cut.
///
/// With `exitThinking`, the guard also follows the row's reasoning channel and
/// keeps every token the row produces: a loop it finds inside the thought asks
/// the scheduler to end the thought and continue the answer
/// (`LoopExitThinkingContinuation`) instead of ending the row as `length`.
public struct GenerationLoopGuard: Sendable {
    /// The served model's `model_type`, for the log line and the metric.
    let modelType: String
    private var detector: GenerationLoopDetector
    private let toolCallMarkers: [String]
    /// Bytes of which every marker holds at least one (`<`, `=`), or none when
    /// some marker holds neither: text without them can't contain a marker, so
    /// the search is skipped.
    private let markerBytes: [UInt8]
    private let carryLength: Int
    /// The end of the previous delta's text, so a marker split across deltas is seen.
    private var carry = ""
    /// Set by a tool-call frame, or once the guard fired: it never fires again.
    private(set) var disarmed = false
    /// The way out of a repeating thought, when this request may take it
    /// (`GenerationLoopExitThinkingPolicy`); nil keeps every stop a `length`.
    let exitThinking: GenerationLoopExitThinking?
    /// Whether the row is inside its reasoning channel (followed with `exitThinking` only).
    private(set) var insideThinking: Bool
    /// The end of the previous delta's text for the channel markers.
    private var channelCarry = ""
    /// Set when the guard's stop ended the thought rather than the answer.
    private(set) var endsThought = false
    /// A tool-call frame turned the guard off: there is no thought to end.
    private var sawToolCall = false

    init(modelType: String, toolCallMarkers: [String],
         thresholds: GenerationLoopDetector.Thresholds = .init(),
         exitThinking: GenerationLoopExitThinking? = nil) {
        self.modelType = modelType
        self.detector = GenerationLoopDetector(thresholds: thresholds)
        self.toolCallMarkers = toolCallMarkers.filter { !$0.isEmpty }
        let probe: [UInt8] = [UInt8(ascii: "<"), UInt8(ascii: "=")]
        self.markerBytes = self.toolCallMarkers.allSatisfy { marker in
            marker.utf8.contains { probe.contains($0) }
        } ? probe : []
        self.carryLength = max(0, (self.toolCallMarkers.map(\.count).max() ?? 1) - 1)
        self.exitThinking = exitThinking
        self.insideThinking = exitThinking?.startsInside ?? false
    }

    /// A fresh guard for the same request without the exit: the continuation's,
    /// so a loop in the answer still ends as `length`.
    func withoutExit() -> GenerationLoopGuard {
        GenerationLoopGuard(modelType: modelType, toolCallMarkers: toolCallMarkers,
                            thresholds: detector.thresholds)
    }

    /// One delta of the row: its text and the tokens behind it. Returns the
    /// detection that should stop the row, at most once.
    mutating func observe(text: String, tokens: [Int]) -> GenerationLoopDetector.Detection? {
        // The continuation resumes after every token the row produced, the
        // in-flight ones after a stop included, so they are all kept.
        if let exitThinking, !sawToolCall {
            exitThinking.record.append(tokens)
        }
        guard !disarmed else {
            // After a stop that ended the thought, the in-flight text still
            // says whether the row closed it itself.
            if endsThought, let exitThinking, !text.isEmpty {
                followChannel(text, markers: exitThinking)
                if !insideThinking { exitThinking.record.noteClosedAfterStop() }
            }
            return nil
        }
        if !toolCallMarkers.isEmpty, !text.isEmpty {
            let scanned = carry + text
            let bytes = markerBytes
            if bytes.isEmpty || scanned.utf8.contains(where: { bytes.contains($0) }),
               toolCallMarkers.contains(where: { scanned.contains($0) }) {
                disarmed = true
                sawToolCall = true
                return nil
            }
            carry = String(scanned.suffix(carryLength))
        }
        if let exitThinking, !text.isEmpty {
            followChannel(text, markers: exitThinking)
        }
        guard let detection = detector.append(tokens) else { return nil }
        disarmed = true
        // A close token in this delta whose text the detokenizer still holds
        // back: the thought has ended, so the stop stays a `length`.
        if let exitThinking, insideThinking, !tokens.contains(exitThinking.closeToken) {
            endsThought = true
            exitThinking.record.requestExit(detection)
        }
        return detection
    }

    /// The last channel marker seen decides whether the row is inside its
    /// thought. A marker split across deltas is seen through `channelCarry`,
    /// one character shorter than the longest marker. A shorter marker (Qwen's
    /// `<think>`) can be seen again from the carry alone; it was already the
    /// last marker then, so the state does not change.
    private mutating func followChannel(_ text: String, markers: GenerationLoopExitThinking) {
        let scanned = channelCarry + text
        if scanned.utf8.contains(UInt8(ascii: "<")) {
            let opened = scanned.range(of: markers.openMarker, options: .backwards)
            let closed = scanned.range(of: markers.closeMarker, options: .backwards)
            switch (opened, closed) {
            case (nil, nil): break
            case (.some, nil): insideThinking = true
            case (nil, .some): insideThinking = false
            case (.some(let open), .some(let close)): insideThinking = open.lowerBound > close.lowerBound
            }
        }
        let keep = max(markers.openMarker.count, markers.closeMarker.count) - 1
        channelCarry = String(scanned.suffix(max(0, keep)))
    }
}
