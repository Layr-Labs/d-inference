// Copyright © 2026 Eigen Labs.

import Testing
@testable import ProviderCore

@Suite("Qwen JSON free-span boundaries", .serialized)
struct QwenJSONFreeSpanTests {
    @Test func jsonPreviewIsPureAndTheAnswerNeverBecomesFree() throws {
        typealias F = QwenAnswerFixture
        let constraint = try F.constraint(F.jsonObject, phase: .reasoning,
            extra: ["ordinary", "</think>{\"a\":1}", "<not-a-marker"])
        #expect(constraint.isFreeSpan(state: 0))
        let count = constraint.cachedStateCount
        for _ in 0..<10 {
            #expect(constraint.isFreeSpanContinuation(state: 0, tokenID: 256))
            for token in [257, 258, 60, F.imEnd, F.endOfText, 248300, -1] {
                #expect(!constraint.isFreeSpanContinuation(state: 0, tokenID: token))
            }
        }
        #expect(constraint.cachedStateCount == count)
        #expect(constraint.nextState(state: 0, tokenID: 256) == 0)
        #expect(constraint.nextState(state: 0, tokenID: 258) == 0)
        let partial = try #require(constraint.nextState(state: 0, tokenID: 60))
        #expect(!constraint.isFreeSpan(state: partial))
        let complete = try #require(F.walk("</think>{\"a\":1}", constraint))
        let trailing = try #require(F.walk(" \n ", constraint, from: complete))
        for state in [complete, trailing, -1, Int.max] {
            #expect(!constraint.isFreeSpan(state: state))
            #expect(!constraint.isFreeSpanContinuation(state: state, tokenID: 256))
        }
        for (schema, answer) in [(#"{"type":"integer"}"#, "42"), (#"{"type":"string"}"#, "\"Rome\"")] {
            let scalar = try F.constraint(F.schemaFormat(schema))
            #expect(!scalar.isFreeSpan(state: 0))
            if answer.hasPrefix("\"") {
                let inside = try #require(F.walk("\"Ro", scalar))
                #expect(!scalar.isFreeSpan(state: inside))
                #expect(!scalar.isFreeSpanContinuation(state: inside, tokenID: 109))
            }
            let done = try #require(F.walk(answer, scalar))
            #expect(!scalar.isFreeSpan(state: done))
            #expect(!scalar.isFreeSpanContinuation(state: done, tokenID: 32))
        }

        // Exhaustion invalidates even the initial reasoning state; speculative
        // preview must never restore a released or impossible grammar.
        var exhausted = false
        for path in 0..<(1 << 13) {
            let text = "</think>{\"a\":" + (0..<13).map { (path >> $0) & 1 == 0 ? "[" : #"{"k":"# }.joined()
            guard F.walk(text, constraint) != nil else { exhausted = true; break }
        }
        #expect(exhausted && constraint.cachedStateCount == JSONAnswerConstraint.maximumStates)
        #expect(!constraint.isFreeSpan(state: 0))
        #expect(!constraint.isFreeSpanContinuation(state: 0, tokenID: 256))
    }

    @Test func otherJSONFamiliesDoNotAcquireFreeSpanSupport() throws {
        typealias F = QwenAnswerFixture
        let profile = JSONAnswerProfile.bonsai2
        let format = try JSONAnswerFormat(try #require(try F.request(format: F.jsonObject).responseFormat),
            forbidding: profile.contentMarkers, family: profile.family)
        let vocabulary = try JSONAnswerVocabulary(pieces: F.vocabulary().pieces,
            profile: profile, stopTokenIDs: F.stops)
        let constraint = try JSONAnswerConstraint(format: format, profile: profile, vocabulary: vocabulary,
            initialPhase: .reasoning, maxTokens: 64)
        #expect(!constraint.isFreeSpan(state: 0))
        #expect(!constraint.isFreeSpanContinuation(state: 0, tokenID: 65))
    }
}
