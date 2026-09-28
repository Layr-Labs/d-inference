import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

final class GenerationScheduleTests: XCTestCase {
    private func request(output: Int = 3) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "schedule-test-v1",
            vocabularySize: 100, hiddenSize: 16, activationDType: "bfloat16",
            maximumPromptTokens: 8, maximumChunkTokens: 2, maximumOutputTokens: 3,
            maximumContextTokens: 16)
        return try .init(profile: profile, requestID: UUID(), promptTokenIDs: [11, 12, 13],
            chunkSize: 2, outputCount: output, stopTokenIDs: [99])
    }

    private func prefilled(output: Int = 3) throws -> QwenLayerStageGenerationSchedule {
        var schedule = QwenLayerStageGenerationSchedule(request: try request(output: output))
        try schedule.commit(schedule.admitPrefill(count: 2, offset: 0, final: false))
        try schedule.commit(schedule.admitPrefill(count: 1, offset: 2, final: true))
        return schedule
    }

    func testRejectedFramesDoNotAdvanceTheFrontier() throws {
        var schedule = QwenLayerStageGenerationSchedule(request: try request())
        XCTAssertThrowsError(try schedule.admitDecode(offset: 0))
        XCTAssertThrowsError(try schedule.admitPrefill(count: 2, offset: 0, final: true))
        let first = try schedule.admitPrefill(count: 2, offset: 0, final: false)
        XCTAssertEqual(schedule.committedTokens, 0)
        XCTAssertThrowsError(try schedule.commit(.init(sequence: 1, phase: .prefill,
            tokenOffset: 0, tokenCount: 2, finalPromptChunk: false)))
        XCTAssertEqual(schedule.nextSequence, 0)
        try schedule.commit(first)
        XCTAssertThrowsError(try schedule.commit(first))
        XCTAssertThrowsError(try schedule.admitPrefill(count: 2, offset: 2, final: true))
        XCTAssertEqual(schedule.committedTokens, 2)
        XCTAssertEqual(schedule.nextSequence, 1)
        let last = try schedule.admitPrefill(count: 1, offset: 2, final: true)
        XCTAssertEqual(last, .init(sequence: 1, phase: .prefill,
            tokenOffset: 2, tokenCount: 1, finalPromptChunk: true))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(last), as: UTF8.self),
            #"{"finalPromptChunk":true,"phase":"prefill","sequence":1,"tokenCount":1,"tokenOffset":2}"#)
        try schedule.commit(last)
        XCTAssertEqual(try schedule.admitDecode(offset: 3), .init(sequence: 2, phase: .decode,
            tokenOffset: 3, tokenCount: 1, finalPromptChunk: false))
    }

    func testEarlyStopRequiresACommittedPromptAndMatchingSelectedFrontier() throws {
        var empty = QwenLayerStageGenerationSchedule(request: try request())
        XCTAssertThrowsError(try empty.finish(.eos, selectedTokenCount: 1, lastTokenID: 99))
        for reason in [QwenLayerStageGenerationFinishReason.eos, .clientStop] {
            var schedule = try prefilled()
            XCTAssertThrowsError(try schedule.finish(.eos, selectedTokenCount: 1, lastTokenID: 14))
            XCTAssertThrowsError(try schedule.finish(reason, selectedTokenCount: 2, lastTokenID: 99))
            XCTAssertFalse(schedule.complete)
            XCTAssertEqual(schedule.committedTokens, 3)
            let token = reason == .eos ? 99 : 14
            try schedule.finish(reason, selectedTokenCount: 1, lastTokenID: token)
            XCTAssertEqual(schedule.finishReason, reason)
            XCTAssertThrowsError(try schedule.admitDecode(offset: 3))
            XCTAssertThrowsError(try schedule.finish(reason, selectedTokenCount: 1, lastTokenID: token))
        }
    }

    func testLengthFinishRequiresAllOutputsAndCannotMaskEOS() throws {
        for output in [1, 3] {
            var schedule = try prefilled(output: output)
            if output > 1 {
                XCTAssertThrowsError(try schedule.finish(.length, selectedTokenCount: 1, lastTokenID: 14))
            }
            for offset in 3..<(3 + output - 1) {
                try schedule.commit(schedule.admitDecode(offset: offset))
            }
            XCTAssertFalse(schedule.complete)
            XCTAssertEqual(schedule.decodeForwardCount, output - 1)
            XCTAssertEqual(schedule.committedTokens, 3 + output - 1)
            XCTAssertThrowsError(try schedule.admitDecode(offset: schedule.committedTokens))
            XCTAssertThrowsError(try schedule.finish(.length, selectedTokenCount: output, lastTokenID: 99))
            try schedule.finish(.length, selectedTokenCount: output, lastTokenID: 14)
            XCTAssertEqual(schedule.finishReason, .length)
        }
    }
}
