// Copyright © 2026 Eigen Labs.

import Foundation

/// One row's loop guard. The detector watches the row's generated tokens; the
/// guard is off for the rest of the row once its text shows a tool-call frame,
/// so a call's arguments (a file of repeated lines, say) are never cut.
public struct GenerationLoopGuard: Sendable {
    /// The served model's `model_type`, for the log line and the metric.
    let modelType: String
    private var detector: GenerationLoopDetector
    private let toolCallMarkers: [String]
    private let carryLength: Int
    /// The end of the previous delta's text, so a marker split across deltas is seen.
    private var carry = ""
    private(set) var disarmed = false

    init(modelType: String, toolCallMarkers: [String],
         thresholds: GenerationLoopDetector.Thresholds = .init()) {
        self.modelType = modelType
        self.detector = GenerationLoopDetector(thresholds: thresholds)
        self.toolCallMarkers = toolCallMarkers.filter { !$0.isEmpty }
        self.carryLength = max(0, (self.toolCallMarkers.map(\.count).max() ?? 1) - 1)
    }

    /// One delta of the row: its text and the tokens behind it. Returns the
    /// detection that should stop the row, at most once.
    mutating func observe(text: String, tokens: [Int]) -> GenerationLoopDetector.Detection? {
        guard !disarmed else { return nil }
        if !toolCallMarkers.isEmpty, !text.isEmpty {
            let scanned = carry + text
            if toolCallMarkers.contains(where: { scanned.contains($0) }) {
                disarmed = true
                return nil
            }
            carry = String(scanned.suffix(carryLength))
        }
        guard let detection = detector.append(tokens) else { return nil }
        disarmed = true
        return detection
    }
}
