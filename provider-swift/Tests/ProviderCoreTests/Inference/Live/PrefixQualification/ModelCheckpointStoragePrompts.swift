import CryptoKit
import Foundation
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Public, generated shipping records with two explicitly synthetic markers.
/// Tokenization uses the production prompt path; requested lengths are floors,
/// and the report records actual prompt and shared-prefix lengths.
struct ModelCheckpointStoragePrompts {
    static let version = "public-shipping-markers-v1; date=2026-10-09; fixed-budget-greedy; marker-is-observation-only"
    static let donorMarker = "ALDER-427"
    static let forkMarker = "BRONZE-913"
    let donor: [Int]
    let fork: [Int]
    let sharedTokens: Int
    let demandedTokens: Int

    init(fixture: ModelPrefixBenchmarkFixture, cell: ModelPrefixBenchmarkSpecification.Case) throws {
        func tokenize(_ text: String) throws -> [Int] {
            let body = try JSONSerialization.data(withJSONObject: [
                "model": fixture.specification.openRouterID,
                "messages": [["role": "user", "content": text]],
                "temperature": 0, "max_tokens": fixture.specification.outputTokens,
                "chat_template_kwargs": ["enable_thinking": false],
            ])
            return try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: fixture.tokenizer.inner,
                modelType: fixture.specification.modelType,
                defaultDate: #require(PromptRenderDate("2026-10-09"))).tokens
        }
        func record(_ index: Int, branch: String) -> String {
            "Record \(index) (\(branch)): station \(index % 17) checked the inlet valve, reconciled the pallet count, "
                + "and scheduled a routine inspection. This record does not change either marker.\n"
        }
        var shared = "This is a synthetic public test. The release marker is \(Self.donorMarker). "
            + "The backup marker is \(Self.forkMarker). Preserve both markers exactly.\n"
        var index = 0
        while try tokenize(shared).count < cell.sharedTokens {
            shared += record(index, branch: "shared")
            index += 1
            try #require(index <= 1_024, "public prompt construction exceeded its bounded record count")
        }
        func prompt(branch: String, minimum: Int, markerName: String) throws -> [Int] {
            var text = shared + "The \(branch) supplement follows.\n"
            var records = 0
            while true {
                let tokens = try tokenize(text + "Return only the \(markerName) marker given at the beginning.")
                try #require(tokens.count <= 20_000, "rendered public prompt exceeded the qualified bound")
                if tokens.count >= minimum { return tokens }
                text += record(records, branch: branch)
                records += 1
                try #require(records <= 1_024)
            }
        }
        donor = try prompt(branch: "donor", minimum: cell.donorTokens, markerName: "release")
        fork = try prompt(branch: "fork", minimum: cell.forkTokens, markerName: "backup")
        sharedTokens = zip(donor, fork).prefix(while: { $0.0 == $0.1 }).count
        demandedTokens = cell.demandedTokens
        try #require(sharedTokens >= demandedTokens && sharedTokens < min(donor.count, fork.count),
            "the rendered public prompts must fork strictly after the demanded checkpoint")
    }

    static func digest(_ tokens: [Int]) throws -> String {
        SHA256.hash(data: try JSONEncoder().encode(tokens)).map { String(format: "%02x", $0) }.joined()
    }
}
