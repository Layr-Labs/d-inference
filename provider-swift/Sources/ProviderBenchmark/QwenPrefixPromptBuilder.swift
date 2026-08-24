import Foundation
import MLXLMCommon

enum QwenPrefixScenarioKind: String, Codable, Sendable {
    case identical
    case commonPrefix = "common-prefix"
}

struct QwenPrefixPreparedScenario: Sendable {
    let id: String
    let kind: QwenPrefixScenarioKind
    let batchSize: Int
    let requestedCommonPrefixFraction: Double?
    let constructedCommonPrefixTokens: Int?
    let donorPrompt: [Int]
    let prompts: [[Int]]
    let suffixIDs: [String]
}

enum QwenPrefixPromptBuilder {
    static let batchSizes = [1, 2, 4]
    static let commonPrefixFractions = [0.25, 0.50, 0.75, 0.90]
    static let commonPrefixBatchSize = 4

    static func prepare(
        corpus: QwenPrefixCorpus,
        promptTokens: Int,
        tokenizer: any Tokenizer
    ) throws -> [QwenPrefixPreparedScenario] {
        try QwenPrefixCorpusLoader.validate(corpus)
        guard promptTokens >= 2 else {
            throw QwenPrefixPromptError.invalidPromptTokens(promptTokens)
        }

        let prefix = tokenizer.encode(
            text: corpus.sharedPrefix,
            addSpecialTokens: false)
        guard !prefix.isEmpty else {
            throw QwenPrefixPromptError.emptyTokenStream("sharedPrefix")
        }
        let suffixes = try corpus.suffixes.map { suffix -> (String, [Int]) in
            let tokens = tokenizer.encode(text: suffix.text, addSpecialTokens: false)
            guard !tokens.isEmpty else {
                throw QwenPrefixPromptError.emptyTokenStream("suffix '\(suffix.id)'")
            }
            return (suffix.id, tokens)
        }

        let identicalPrompt = tile(
            prefix + suffixes[0].1,
            count: promptTokens,
            offset: 0)
        var scenarios = batchSizes.map { batchSize in
            QwenPrefixPreparedScenario(
                id: "identical-b\(batchSize)",
                kind: .identical,
                batchSize: batchSize,
                requestedCommonPrefixFraction: 1,
                constructedCommonPrefixTokens: promptTokens,
                donorPrompt: identicalPrompt,
                prompts: Array(repeating: identicalPrompt, count: batchSize),
                suffixIDs: Array(repeating: suffixes[0].0, count: batchSize))
        }

        let selectedSuffixes = try selectDistinctSuffixStarts(
            Array(suffixes.prefix(QwenPrefixCorpusLoader.minimumSuffixes)))
        for fraction in commonPrefixFractions {
            let commonTokens = Int((Double(promptTokens) * fraction).rounded(.down))
            guard commonTokens > 0, commonTokens < promptTokens else {
                throw QwenPrefixPromptError.invalidCommonPrefix(
                    fraction: fraction,
                    promptTokens: promptTokens)
            }
            let shared = tile(prefix, count: commonTokens, offset: 0)
            let donor = shared + tile(
                selectedSuffixes[0].tokens,
                count: promptTokens - commonTokens,
                offset: selectedSuffixes[0].offset)
            let rows = selectedSuffixes.dropFirst().prefix(commonPrefixBatchSize).map {
                shared + tile(
                    $0.tokens,
                    count: promptTokens - commonTokens,
                    offset: $0.offset)
            }
            guard rows.count == commonPrefixBatchSize else {
                throw QwenPrefixPromptError.insufficientSuffixes(
                    expected: commonPrefixBatchSize + 1,
                    actual: selectedSuffixes.count)
            }
            for (row, prompt) in rows.enumerated() {
                let actual = commonPrefixLength(donor, prompt)
                guard actual == commonTokens else {
                    throw QwenPrefixPromptError.prefixConstructionMismatch(
                        row: row,
                        expected: commonTokens,
                        actual: actual)
                }
            }
            scenarios.append(QwenPrefixPreparedScenario(
                id: "common-prefix-\(Int(fraction * 100))",
                kind: .commonPrefix,
                batchSize: commonPrefixBatchSize,
                requestedCommonPrefixFraction: fraction,
                constructedCommonPrefixTokens: commonTokens,
                donorPrompt: donor,
                prompts: Array(rows),
                suffixIDs: Array(
                    selectedSuffixes.dropFirst().prefix(commonPrefixBatchSize).map(\.id))))
        }
        return scenarios
    }

    static func commonPrefixLength(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).prefix(while: { $0.0 == $0.1 }).count
    }

    private struct SelectedSuffix {
        let id: String
        let tokens: [Int]
        let offset: Int
    }

    /// Pick a distinct first token for every suffix. This makes the requested
    /// token boundary the exact divergence point instead of merely a lower
    /// bound whose suffixes happen to share another tokenizer token.
    private static func selectDistinctSuffixStarts(
        _ suffixes: [(String, [Int])]
    ) throws -> [SelectedSuffix] {
        var used: Set<Int> = []
        var selected: [SelectedSuffix] = []
        for (id, tokens) in suffixes {
            guard let offset = tokens.indices.first(where: { !used.contains(tokens[$0]) }) else {
                throw QwenPrefixPromptError.noDistinctSuffixStart(id)
            }
            used.insert(tokens[offset])
            selected.append(SelectedSuffix(id: id, tokens: tokens, offset: offset))
        }
        return selected
    }

    private static func tile(
        _ source: [Int],
        count: Int,
        offset: Int
    ) -> [Int] {
        guard count > 0 else { return [] }
        precondition(!source.isEmpty)
        return (0 ..< count).map { source[(offset + $0) % source.count] }
    }
}

enum QwenPrefixPromptError: Error, Equatable, CustomStringConvertible {
    case invalidPromptTokens(Int)
    case emptyTokenStream(String)
    case insufficientSuffixes(expected: Int, actual: Int)
    case noDistinctSuffixStart(String)
    case invalidCommonPrefix(fraction: Double, promptTokens: Int)
    case prefixConstructionMismatch(row: Int, expected: Int, actual: Int)

    var description: String {
        switch self {
        case .invalidPromptTokens(let count):
            return "Qwen prefix prompt length must be at least 2 tokens (got \(count))"
        case .emptyTokenStream(let field):
            return "Qwen prefix corpus \(field) tokenized to an empty stream"
        case .insufficientSuffixes(let expected, let actual):
            return "Qwen prefix workload requires \(expected) suffixes, found \(actual)"
        case .noDistinctSuffixStart(let id):
            return "Qwen prefix suffix '\(id)' has no token distinct from earlier suffix starts"
        case .invalidCommonPrefix(let fraction, let promptTokens):
            return "Qwen prefix fraction \(fraction) cannot be represented inside "
                + "a \(promptTokens)-token prompt"
        case .prefixConstructionMismatch(let row, let expected, let actual):
            return "Qwen prefix row \(row) shares \(actual) tokens; expected exactly \(expected)"
        }
    }
}
