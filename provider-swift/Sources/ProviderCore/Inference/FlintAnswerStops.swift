// Copyright © 2026 Eigen Labs.

import Foundation

/// Client `stop` sequences for exact Flint, matched only against visible answer
/// bytes: output the native boundary commits in its initial/content phases.
/// Reasoning spans, tool-call frames and their arguments never advance a match,
/// and a match never spans a reasoning close. The token constraint (termination)
/// and the stream filter (client text) both classify bytes through this type, so
/// they observe the same first match. Matching is exact over UTF-8 bytes, which
/// equals scalar matching for the valid UTF-8 the stream carries.
struct FlintAnswerStops: Sendable {
    struct Match: Equatable {
        /// Index into `sequences`.
        let sequence: Int
        /// Matched byte length.
        let length: Int
    }

    /// Effect of one output byte. Committed answer bytes are the oldest bytes of
    /// the boundary's marker window; `pending` marker bytes remain undecided.
    struct Step {
        /// The byte was consumed in the answer channel (not reasoning or a frame).
        let answerByte: Bool
        /// The answer channel is still open after this byte.
        let inAnswer: Bool
        let committed: Int
        let pending: Int
        /// First completed sequence, at a committed-byte offset in `0..<committed`.
        let match: (offset: Int, match: Match)?
    }

    /// Original spellings, in request order, for the matched-sequence signal.
    let sequences: [String]
    private let patterns: [[UInt8]]
    private let failures: [[Int]]

    /// `sequences` must be non-empty strings already within the factory limits.
    init(_ sequences: [String]) {
        self.sequences = sequences
        patterns = sequences.map { Array($0.utf8) }
        failures = patterns.map(Self.failureTable)
    }

    var initialProgress: [Int] { [Int](repeating: 0, count: patterns.count) }

    static func inAnswer(_ boundary: FlintNativeProtocolBoundary,
                         rules: FlintNativeProtocolBoundary.Rules) -> Bool {
        !rules.requiresCall && (boundary.phase == .initial || boundary.phase == .content)
    }

    /// Advances `boundary` by one output byte and `progress` by every byte that
    /// byte commits to the answer. Returns nil when the boundary rejects it.
    func step(_ byte: UInt8, boundary: inout FlintNativeProtocolBoundary, progress: inout [Int],
              rules: FlintNativeProtocolBoundary.Rules) -> Step? {
        let answerByte = Self.inAnswer(boundary, rules: rules)
        let window = answerByte ? boundary.marker + [byte] : []
        guard boundary.consume([byte], rules: rules) else { return nil }
        let inAnswer = Self.inAnswer(boundary, rules: rules)
        // Leaving the answer means a complete opening matched; it is framing.
        let retained = inAnswer ? boundary.marker.count
            : (boundary.phase == .reasoning ? FlintNativeProtocolBoundary.think.count
                : FlintNativeProtocolBoundary.call.count)
        let committed = max(0, window.count - retained)
        var match: (offset: Int, match: Match)?
        for offset in 0..<committed {
            if let found = advance(&progress, byte: window[offset]) {
                match = (offset, found)
                break
            }
        }
        if !inAnswer { progress = initialProgress }
        return Step(answerByte: answerByte, inAnswer: inAnswer, committed: committed,
                    pending: inAnswer ? boundary.marker.count : 0, match: match)
    }

    /// Feeds one committed answer byte. The longest sequence ending here wins,
    /// so the earliest start is cut when several complete together.
    func advance(_ progress: inout [Int], byte: UInt8) -> Match? {
        var found: Match?
        for index in patterns.indices {
            let pattern = patterns[index]
            var length = progress[index]
            while length > 0, pattern[length] != byte { length = failures[index][length - 1] }
            if pattern[length] == byte { length += 1 }
            if length == pattern.count {
                if length > found?.length ?? 0 { found = Match(sequence: index, length: length) }
                length = failures[index][length - 1]
            }
            progress[index] = length
        }
        return found
    }

    /// Earliest offset in trailing answer bytes from which a sequence could still
    /// match: the tail is a sequence prefix, or contains one that ends in bytes
    /// the boundary has not committed yet. Everything before it is safe to emit.
    func earliestPossibleStart(in run: [UInt8]) -> Int {
        for start in run.indices {
            let tail = run[start...]
            if patterns.contains(where: { pattern in
                let count = min(pattern.count, tail.count)
                return tail.prefix(count).elementsEqual(pattern.prefix(count))
            }) { return start }
        }
        return run.count
    }

    private static func failureTable(_ pattern: [UInt8]) -> [Int] {
        var table = [Int](repeating: 0, count: pattern.count)
        var length = 0
        for index in pattern.indices.dropFirst() {
            while length > 0, pattern[index] != pattern[length] { length = table[length - 1] }
            if pattern[index] == pattern[length] { length += 1 }
            table[index] = length
        }
        return table
    }
}

/// Client-text side of Flint answer stops. Raw output passes through unchanged
/// apart from delay: only the minimal suffix that could still become a stop is
/// held, and a match discards the sequence and everything after it before the
/// channel splitter or tool parser sees it. Held bytes stay bounded by the
/// longest sequence plus one undecided protocol-marker prefix.
struct FlintAnswerStopFilter: Sendable {
    private let stops: FlintAnswerStops
    private let rules: FlintNativeProtocolBoundary.Rules
    private var boundary: FlintNativeProtocolBoundary
    private var progress: [Int]
    private var held: [UInt8] = []
    /// Set if text ever disagrees with the protocol the constraint enforced;
    /// such output is released unchanged rather than guessed at.
    private var unclassified = false
    private(set) var matchedSequence: String?

    init(stops: FlintAnswerStops, rules: FlintNativeProtocolBoundary.Rules,
         boundary: FlintNativeProtocolBoundary) {
        self.stops = stops
        self.rules = rules
        self.boundary = boundary
        progress = stops.initialProgress
    }

    mutating func ingest(_ text: String) -> String {
        guard matchedSequence == nil else { return "" }
        guard !unclassified else { return text }
        let bytes = Array(text.utf8)
        var released: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            held.append(byte)
            guard let step = stops.step(byte, boundary: &boundary, progress: &progress, rules: rules) else {
                unclassified = true
                released += held + bytes[(index + 1)...]
                held = []
                return String(decoding: released, as: UTF8.self)
            }
            if let found = step.match {
                cut(at: held.count - step.pending - step.committed + found.offset, match: found.match,
                    into: &released)
                return String(decoding: released, as: UTF8.self)
            }
            if !step.answerByte || !step.inAnswer {
                released += held
                held = []
            }
        }
        let start = stops.earliestPossibleStart(in: held)
        released += held[..<start]
        held.removeFirst(start)
        return String(decoding: released, as: UTF8.self)
    }

    /// Natural end of output: the splitter publishes an undecided marker prefix
    /// as answer text, so those bytes commit here before the tail is released.
    mutating func finish() -> String {
        guard matchedSequence == nil else { return "" }
        var released: [UInt8] = []
        if !unclassified, FlintAnswerStops.inAnswer(boundary, rules: rules) {
            let pending = boundary.marker
            for (offset, byte) in pending.enumerated() {
                if let match = stops.advance(&progress, byte: byte) {
                    cut(at: held.count - pending.count + offset, match: match, into: &released)
                    return String(decoding: released, as: UTF8.self)
                }
            }
        }
        released = held
        held = []
        return String(decoding: released, as: UTF8.self)
    }

    private mutating func cut(at end: Int, match: FlintAnswerStops.Match, into released: inout [UInt8]) {
        // Holdback keeps every possible match start, so `start` is never negative.
        let start = max(0, end - match.length + 1)
        released += held[..<min(start, held.count)]
        held = []
        matchedSequence = stops.sequences[match.sequence]
    }
}
