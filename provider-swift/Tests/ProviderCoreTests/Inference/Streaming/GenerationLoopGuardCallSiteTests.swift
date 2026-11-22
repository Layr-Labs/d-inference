// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

/// Swift source with its comments and string literals replaced by spaces
/// (line breaks kept), so a search sees neither prose nor quoted text and a
/// bracket inside either never moves the end of a call.
private struct SwiftCode {
    private(set) var bytes: [UInt8]
    private var index = 0

    private static let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " ")
    private static let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), backslash = UInt8(ascii: "\\")
    private static let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#")
    private static let openParen = UInt8(ascii: "("), closeParen = UInt8(ascii: ")")

    init(_ source: String) {
        bytes = Array(source.utf8)
        scanCode(insideInterpolation: false)
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    private func byte(at offset: Int) -> UInt8? { offset < bytes.count ? bytes[offset] : nil }

    /// Code to the end of the text or, inside a string's `\(`, to the `)` that closes it.
    private mutating func scanCode(insideInterpolation: Bool) {
        var depth = 0
        while let current = byte(at: index) {
            switch current {
            case Self.slash where byte(at: index + 1) == Self.slash:
                let start = index
                while let next = byte(at: index), next != Self.newline { index += 1 }
                blank(start..<index)
            case Self.slash where byte(at: index + 1) == Self.star:
                scanBlockComment()
            case Self.quote:
                scanString(hashes: 0)
            case Self.hash:
                var hashes = 0
                while byte(at: index + hashes) == Self.hash { hashes += 1 }
                if byte(at: index + hashes) == Self.quote { scanString(hashes: hashes) } else { index += hashes }
            case Self.openParen where insideInterpolation:
                depth += 1
                index += 1
            case Self.closeParen where insideInterpolation:
                if depth == 0 { return }
                depth -= 1
                index += 1
            default:
                index += 1
            }
        }
    }

    /// Block comments nest in Swift.
    private mutating func scanBlockComment() {
        let start = index
        var depth = 0
        while let current = byte(at: index) {
            if current == Self.slash, byte(at: index + 1) == Self.star {
                depth += 1
                index += 2
            } else if current == Self.star, byte(at: index + 1) == Self.slash {
                depth -= 1
                index += 2
                if depth == 0 { break }
            } else {
                index += 1
            }
        }
        blank(start..<index)
    }

    /// A string literal from its opening delimiter (at `index`) through its
    /// closing one, the code it interpolates included.
    private mutating func scanString(hashes: Int) {
        let start = index
        index += hashes
        let multiline = byte(at: index + 1) == Self.quote && byte(at: index + 2) == Self.quote
        let quotes = multiline ? 3 : 1
        index += quotes
        scan: while let current = byte(at: index) {
            switch current {
            case Self.backslash where hashesFollow(index + 1, count: hashes):
                let escaped = index + 1 + hashes
                index = escaped + 1
                if byte(at: escaped) == Self.openParen {
                    scanCode(insideInterpolation: true)
                    index += 1
                }
            case Self.quote where closesString(at: index, quotes: quotes, hashes: hashes):
                index += quotes + hashes
                break scan
            case Self.newline where !multiline:
                // An unterminated literal ends with its line.
                break scan
            default:
                index += 1
            }
        }
        blank(start..<min(index, bytes.count))
    }

    private func closesString(at offset: Int, quotes: Int, hashes: Int) -> Bool {
        (0..<quotes).allSatisfy { byte(at: offset + $0) == Self.quote }
            && hashesFollow(offset + quotes, count: hashes)
    }

    private func hashesFollow(_ offset: Int, count: Int) -> Bool {
        (0..<count).allSatisfy { byte(at: offset + $0) == Self.hash }
    }

    private mutating func blank(_ range: Range<Int>) {
        for offset in range where bytes[offset] != Self.newline { bytes[offset] = Self.space }
    }
}

/// One call of a function, read from source text.
private struct ScannedCall: Equatable {
    /// 1-based line of the call's name.
    let line: Int
    /// The expression the call passes as `loopGuard:`; nil when it names none.
    let loopGuard: String?
}

private enum CallScan {
    struct UnterminatedCall: Error { let line: Int }

    /// Every call of `name` in `source`, in order; never its declaration.
    static func calls(of name: String, in source: String) throws -> [ScannedCall] {
        let code = SwiftCode(source).bytes
        let name = Array(name.utf8)
        var calls: [ScannedCall] = []
        var offset = 0
        while offset + name.count < code.count {
            guard code[offset...].starts(with: name), offset == 0 || !isIdentifier(code[offset - 1]) else {
                offset += 1
                continue
            }
            var open = offset + name.count
            while open < code.count, isWhitespace(code[open]) { open += 1 }
            if open < code.count, code[open] == UInt8(ascii: "("), !isDeclaration(code, nameAt: offset) {
                let line = 1 + code[..<offset].count(where: { $0 == UInt8(ascii: "\n") })
                calls.append(ScannedCall(
                    line: line, loopGuard: try argument("loopGuard", in: code, open: open, line: line)))
            }
            offset += name.count
        }
        return calls
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r")
    }

    private static func isDeclaration(_ code: [UInt8], nameAt offset: Int) -> Bool {
        var end = offset
        while end > 0, isWhitespace(code[end - 1]) { end -= 1 }
        let keyword = Array("func".utf8)
        guard end >= keyword.count, code[(end - keyword.count)..<end].elementsEqual(keyword) else { return false }
        return end == keyword.count || !isIdentifier(code[end - keyword.count - 1])
    }

    /// The expression a call passes for the argument `label`, from the call's
    /// `(` at `open`; nil when it names none. Only the call's own labels
    /// count: one inside a nested call, a closure or a ternary does not.
    private static func argument(_ label: String, in code: [UInt8], open: Int, line: Int) throws -> String? {
        let label = Array(label.utf8)
        var depth = 0
        // The last byte of the call's own argument list that is not whitespace.
        var previous = UInt8(ascii: "(")
        var start: Int?
        var index = open
        while index < code.count {
            switch code[index] {
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return start.map { text(code[$0..<index]) } }
            case UInt8(ascii: ",") where depth == 1 && start != nil:
                return start.map { text(code[$0..<index]) }
            default:
                let startsArgument = previous == UInt8(ascii: "(") || previous == UInt8(ascii: ",")
                if depth == 1, start == nil, startsArgument, code[index...].starts(with: label) {
                    var after = index + label.count
                    while after < code.count, isWhitespace(code[after]) { after += 1 }
                    if after < code.count, code[after] == UInt8(ascii: ":") {
                        start = after + 1
                        index = after
                    }
                }
            }
            if depth == 1, !isWhitespace(code[index]) { previous = code[index] }
            index += 1
        }
        throw UnterminatedCall(line: line)
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A row submitted without a loop guard is a decision, never an omission.
/// `EngineV2Bridge.submitTokenized` defaults `loopGuard:` to nil, so a call
/// that leaves it out compiles and its answers that repeat run to their cap.
/// These tests read the production sources: every call passes a guard it
/// resolved or names its exemption (`GenerationLoopGuardPolicy.RouteExemption`).
@Suite("Loop guard: every production submission says which guard it takes")
struct GenerationLoopGuardCallSiteTests {
    private typealias Exemption = GenerationLoopGuardPolicy.RouteExemption

    private struct Site {
        let file: String
        let call: ScannedCall
        var location: String { "\(file):\(call.line)" }
    }

    /// Every Swift source under `provider-swift/Sources`, by file name; read once.
    private static let sources = Result<[(file: String, text: String)], any Error> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var sources: [(file: String, text: String)] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return sources.sorted { $0.file < $1.file }
    }

    private static func productionSources() throws -> [(file: String, text: String)] {
        let sources = try Self.sources.get()
        #expect(sources.count > 100, "found only \(sources.count) source files")
        return sources
    }

    /// Every call of `name` in the production sources.
    private static func productionCalls(of name: String) throws -> [Site] {
        try productionSources().filter { $0.text.contains(name) }.flatMap { source in
            try CallScan.calls(of: name, in: source.text).map { Site(file: source.file, call: $0) }
        }
    }

    /// The exemption an argument names: `GenerationLoopGuardPolicy.exempt(.pairMedia)` gives `pairMedia`.
    private static func exemption(_ expression: String) -> String? {
        let prefix = "GenerationLoopGuardPolicy.exempt(.", suffix = ")"
        guard expression.hasPrefix(prefix), expression.hasSuffix(suffix) else { return nil }
        return String(expression.dropFirst(prefix.count).dropLast(suffix.count))
    }

    @Test("no production call leaves `loopGuard:` out or passes a bare nil")
    func everyProductionSubmissionNamesItsLoopGuard() throws {
        let sites = try Self.productionCalls(of: "submitTokenized")
        #expect(!sites.isEmpty, "found no submitTokenized call")
        let omitted = sites.filter { $0.call.loopGuard == nil }.map(\.location)
        #expect(omitted.isEmpty, "submitTokenized calls that name no loopGuard: \(omitted)")
        let bareNil = sites.filter { $0.call.loopGuard == "nil" }.map(\.location)
        #expect(bareNil.isEmpty, "submitTokenized calls that pass `loopGuard: nil`: \(bareNil)")
    }

    /// A new unguarded route changes this table, so it is added on purpose
    /// and reviewed as one.
    @Test("each exemption is named at the submissions this table lists, and nowhere else")
    func exemptRoutesArePinned() throws {
        let pinned: [Exemption: [String: Int]] = [
            .pairMedia: ["MultiModelBatchSchedulerEngine.swift": 4],
            .nativeMiMoMedia: ["MultiModelBatchSchedulerEngine.swift": 1],
            .mimoDecodedMedia: ["MiMoV26ServingLoad.swift": 1],
            .directSubmit: ["EngineV2Bridge+Submission.swift": 1],
            .modelCalibration: ["EngineV2Bridge+ModelCalibrationRequests.swift": 1],
        ]
        #expect(Set(pinned.keys) == Set(Exemption.allCases))
        var named: [String: [String: Int]] = [:]
        for site in try Self.productionCalls(of: "submitTokenized") {
            guard let exemption = site.call.loopGuard.flatMap(Self.exemption) else { continue }
            named[exemption, default: [:]][site.file, default: 0] += 1
        }
        #expect(named == Dictionary(uniqueKeysWithValues: pinned.map { ("\($0.key)", $0.value) }))
        // An exemption held in a variable or passed through another function
        // would be out of this table's sight.
        let exemptSubmissions = named.values.flatMap(\.values).reduce(0, +)
        #expect(try Self.productionCalls(of: "exempt").count == exemptSubmissions)
        for route in Exemption.allCases {
            #expect(!route.reason.isEmpty, "\(route)")
        }
    }

    /// A defaulted `loopGuard` parameter is what lets a caller leave the
    /// guard out. The scan above reads every caller of the bridge's own
    /// entry points; the callers of any other function with such a default
    /// are outside it, so that list stays closed: Super's text binding
    /// (`NemotronSuperLocalBinding.run`), whose production caller passes the
    /// request plan's guard.
    @Test("only the bridge's entry points and Super's text binding default `loopGuard` to nil")
    func defaultedLoopGuardParametersArePinned() throws {
        let defaulted = try Regex(#"loopGuard\s*:\s*GenerationLoopGuard\?\s*=\s*nil"#)
        var found: [String: Int] = [:]
        for source in try Self.productionSources() where source.text.contains("loopGuard") {
            let count = SwiftCode(source.text).text.matches(of: defaulted).count
            if count > 0 { found[source.file] = count }
        }
        #expect(found == [
            "EngineV2Bridge+Events.swift": 2,
            "EngineV2Bridge+Submission.swift": 3,
            "NemotronSuperLocalBinding.swift": 1,
        ])
    }

    @Test("the scan reads a call's own `loopGuard:` through comments, strings and nested calls")
    func scanReadsCallSites() throws {
        let source = #"""
            public func submitTokenized(promptTokens: [Int], loopGuard: GenerationLoopGuard? = nil) async {}
            func caller() async throws {
                // submitTokenized(promptTokens: [], loopGuard: nil) in a comment is not a call
                let note = "bridge.submitTokenized(promptTokens: [], loopGuard: quoted)"
                _ = await bridge.submitTokenized(promptTokens: tokens,
                    request: translate(request, loopGuard: nested),  // loopGuard: a comment with a )
                    requestId: "id-\(make(")"))", cacheEnabled: flag ? loopGuard : other)
                _ = await submitTokenized(
                    promptTokens: tokens, /* a ) inside /* a nested */ block comment */
                    loopGuard: GenerationLoopGuardPolicy.resolve(modelType: type, request: request))
                _ = try await bridge.submitTokenized(promptTokens: tokens, loopGuard: nil, requestId: id)
                _ = await submitTokenizedAttempt(promptTokens: tokens)
                _ = await bridge.submitTokenized (promptTokens: tokens)
            }
            """#
        #expect(try CallScan.calls(of: "submitTokenized", in: source) == [
            ScannedCall(line: 5, loopGuard: nil),
            ScannedCall(line: 8, loopGuard: "GenerationLoopGuardPolicy.resolve(modelType: type, request: request)"),
            ScannedCall(line: 11, loopGuard: "nil"),
            ScannedCall(line: 13, loopGuard: nil),
        ])
        #expect(throws: CallScan.UnterminatedCall.self) {
            try CallScan.calls(of: "submitTokenized", in: "bridge.submitTokenized(promptTokens: tokens,")
        }
    }
}
