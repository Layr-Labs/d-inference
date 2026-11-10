// Copyright © 2026 Eigen Labs.
// The template boundary rule on real snapshots. Tokenizer and template files
// only; no weights are read.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Run against local snapshots:
/// `DARKBLOOM_TEST_TEMPLATE_RULE_DIRS=<snapshot>[:<snapshot>…]`. Prints the
/// line the provider logs at load. An accepted rule is then checked on a
/// conversation the derivation never rendered.
@Suite(
    "Template boundary rule real tokenizers",
    .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_TEMPLATE_RULE_DIRS"] != nil))
struct TemplateBoundaryRuleRealTokenizerTests {
    private static let head: [Message] = [
        ["role": "system", "content": "You answer questions about cooking."],
        ["role": "user", "content": "How long do I boil an egg for a soft yolk?"],
    ]
    private static let reply: Message = [
        "role": "assistant",
        "content": "About six minutes.\n\n1. Boil the water.\n2. Lower the egg in.\n\n```\ntimer 6m\n```",
    ]
    private static let followUp: Message = ["role": "user", "content": "And for a hard yolk?"]
    private static let otherFollowUp: Message = [
        "role": "user", "content": "Should I salt the water — sí o no?",
    ]

    @Test func anAcceptedRuleHoldsOnAnotherConversation() async throws {
        let directories = try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_TEST_TEMPLATE_RULE_DIRS"]
        ).split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        for directory in directories {
            let name = directory.lastPathComponent
            let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
            let modelType = ModelScanner.parseConfigJSON(
                at: directory.appendingPathComponent("config.json")
            ).modelType
            let derivation = TemplateBoundaryRule.derive(
                tokenizer: tokenizer, modelType: modelType, modelID: name)
            let family = modelType ?? "unknown"
            print("template-boundary-rule \(family): \(TemplateBoundaryRule.summary(of: derivation))")
            guard let rule = derivation.rule else { continue }

            func prompt(_ messages: [Message], generationPrompt: Bool = true) throws -> [Int] {
                try ProviderPromptContractPipeline.tokenizeProviderBody(
                    try TemplateBoundaryRule.requestBody(
                        for: CBv2BoundaryProbe(
                            messages: messages, addGenerationPrompt: generationPrompt),
                        modelID: name),
                    tokenizer: tokenizer, modelType: modelType,
                    addGenerationPrompt: generationPrompt)
            }
            let first = try prompt(Self.head)
            // Without the generation prompt the same request stops before its header.
            let unopened = try prompt(Self.head, generationPrompt: false)
            #expect(unopened.count < first.count && first.starts(with: unopened), "\(name)")
            let second = try prompt(Self.head + [Self.reply, Self.followUp])
            let other = try prompt(Self.head + [Self.reply, Self.otherFollowUp])
            let boundaries = rule.boundaries(in: second)

            // The first prompt's last boundary is one of the second prompt's.
            let opened = try #require(rule.boundaries(in: first).last, "\(name)")
            #expect(opened <= sharedCount(first, second), "\(name)")
            #expect(boundaries.contains(opened), "\(name)")
            // The reply ends on a boundary inside the history both follow-ups share.
            let history = sharedCount(second, other)
            let replyEnd = boundaries.last { $0 <= history }
            #expect((replyEnd ?? 0) > opened, "\(name)")
            print(
                "template-boundary-rule \(family): first_prompt=\(first.count) opened=\(opened)"
                    + " shared_history=\(history) reply_end=\(replyEnd ?? 0)")
        }
    }
}

private func sharedCount(_ one: [Int], _ other: [Int]) -> Int {
    zip(one, other).prefix { $0 == $1 }.count
}
