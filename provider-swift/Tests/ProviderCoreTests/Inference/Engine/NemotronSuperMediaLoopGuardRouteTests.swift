// Copyright © 2026 Eigen Labs.
@preconcurrency import AVFoundation
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import MLXVLM
@testable import ProviderCore

/// The image owner's encoded route (`runEncoded`, the route Super's HTTP hook
/// serves images and video through) resolves the request plan's loop guard and
/// submits each image and video row with it, on the tiny installed owner.
@Suite(.serialized)
struct NemotronSuperMediaLoopGuardRouteTests {
    private static let defaults = GenerationLoopGuardPolicy.Setting.modelTypes(
        GenerationLoopGuardPolicy.defaultModelTypes)

    @Test(.timeLimit(.minutes(3)))
    func imageAndVideoRowsAreSubmittedWithThePlansGuard() async throws {
        let session = try await MediaGuardSession.make()
        let observed = SubmittedGuards()
        await session.media.setTestSubmission { observed.record($0) }
        for body in [session.videoBody, session.imageBody] {
            try await session.run(body, setting: Self.defaults)
        }
        let guards = observed.all
        #expect(guards.count == 2)
        #expect(guards.allSatisfy { $0?.modelType == "nemotron_h_omni" && $0?.exitThinking == nil })
        try await session.close()
    }

    @Test(.timeLimit(.minutes(3)))
    func theSwitchAndTheExclusionsLeaveMediaRowsUnguarded() async throws {
        let session = try await MediaGuardSession.make()
        let observed = SubmittedGuards()
        await session.media.setTestSubmission { observed.record($0) }
        try await session.run(session.videoBody, setting: .off)
        try await session.run(session.imageBody, setting: .modelTypes(["nemotron_h"]))
        let json = try MediaGuardSession.body(["type": "image_url", "image_url": ["url": MediaGuardSession.png]],
            extras: ["response_format": ["type": "json_object"]])
        try await session.run(json, setting: Self.defaults)
        #expect(observed.all.count == 3)
        #expect(observed.all.allSatisfy { $0 == nil })
        try await session.close()
    }
}

private final class SubmittedGuards: @unchecked Sendable {
    private let lock = NSLock()
    private var guards: [GenerationLoopGuard?] = []
    var all: [GenerationLoopGuard?] { lock.withLock { guards } }
    func record(_ loopGuard: GenerationLoopGuard?) { lock.withLock { guards.append(loopGuard) } }
}

/// The tiny batched-decode Super installation with the encoded three-channel
/// 16-pixel tower: one owner prepares an image and a square clip.
private struct MediaGuardSession: @unchecked Sendable {
    let owner: NemotronSuperLocalBridgeBuilder.Owner
    let media: NemotronSuperLocalImageBinding
    let budget: GlobalKVCacheBudget
    let lease: PendingModelLoadLease
    let fixture: SuperMTPInstalledFixture.Installation
    let videoBody: Data
    let imageBody: Data

    static let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="

    static func make() async throws -> Self {
        let fixture = try SuperMTPInstalledFixture(radioDimensions: SuperMTPInstalledFixture.encodedImageTower).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-media-guard-" + UUID().uuidString,
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes), minimumKVBytes: 4 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperSyntheticVideoTokenizer()), eosTokenIDs: [],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 2), kvBytesCapacity: 4 << 30,
            kvBudget: budget, loadLease: lease, construction: fixture.construction, environment: [:])
        let clip = try await MiMoEncodedMediaFixtures.video(frames: 10, fps: 4, width: 64, height: 64)
        let videoBody = try body(["type": "video_url", "video_url": ["url":
            "data:video/mp4;base64," + clip.base64EncodedString()]])
        let imageBody = try body(["type": "image_url", "image_url": ["url": png]])
        return Self(owner: owner, media: try owner.localImageBinding(), budget: budget, lease: lease,
            fixture: fixture, videoBody: videoBody, imageBody: imageBody)
    }

    static func body(_ part: [String: Any], extras: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = [
            "model": NemotronSuperLocalBinding.modelID, "max_tokens": 2, "temperature": 0,
            "messages": [["role": "user", "content": [["type": "text", "text": "fixture"], part]]],
        ]
        for (key, item) in extras { value[key] = item }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func run(_ body: Data, setting: GenerationLoopGuardPolicy.Setting) async throws {
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                         options: .ignoreUnknownCharacters))
        let events = SuperVideoEvents()
        try await media.runEncoded(body: body, plan: NemotronSuperRequestPlan(body: body), templateBytes: template,
                                   loopGuardSetting: setting) { await events.record($0) }
        #expect(await events.errors.isEmpty)
        #expect(await events.completions == [2])
    }

    func close() async throws {
        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
