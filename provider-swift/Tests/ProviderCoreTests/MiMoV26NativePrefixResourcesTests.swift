// Copyright © 2026 Eigen Labs.
import CryptoKit
import Foundation
import MLXLMCommon
import XCTest
@testable import ProviderCore

/// Existing encrypted store, existing budget and real zero-charge owner. These
/// host tests do not claim GPU coverage or a successful native retirement.
enum MiMoPrefixStoreTestSupport {
    static let identity = CBv2CompleteCheckpointIdentity(
        modelAggregateHash: String(repeating: "a", count: 64),
        promptContractID: String(repeating: "b", count: 64),
        buildID: String(repeating: "c", count: 64), numericsFingerprint: String(repeating: "d", count: 64))

    static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
            configReserveBytes: 4 << 30, memorySnapshot: {
                .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
            })
    }
    static func store(budget: GlobalKVCacheBudget, layout: String) throws -> SSDHybridCheckpointStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("mimo-prefix-owner-" + UUID().uuidString, isDirectory: true)
        let modelRoot = root.appendingPathComponent("0123456789ab", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        return SSDHybridCheckpointStore(config: .init(modelId: "synthetic-native-mimo-prefix",
            identity: identity, backendLayout: layout, root: modelRoot, dedicatedRoot: root,
            epochStore: nil, maxReadBytes: 16 << 20, maxStageMillis: 1000, minEffectiveTokens: 256,
            ttlSeconds: 3600, strictFsync: false, nowSeconds: { Int64(Date().timeIntervalSince1970) },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: SymmetricKey(size: .bits256), kvBudget: budget,
            diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
    }
}

final class MiMoV26NativePrefixResourcesTests: XCTestCase {
    func testDefaultOffAndMediaCannotSilentlySelectTextPrefixProfile() {
        let model = "EigenLabs/MiMo-V2.6-Flash-MOPD-MLX-4bit-mtp"
        func refusal(_ env: [String: String], media: Bool = false) -> PrefixCacheStatusReason? {
            EngineV2SlotFactory.nativeMiMoPrefixRefusal(modelId: model, hasMedia: media, environment: env)
        }
        XCTAssertEqual(refusal([:]), .configDisabled)
        XCTAssertEqual(refusal(["DARKBLOOM_PREFIX_CACHE": "1"]), .configDisabled)
        XCTAssertEqual(refusal(["DARKBLOOM_MIMO_COMPLETE_PREFIX": "1"]), .configDisabled)
        let on = ["DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_MIMO_COMPLETE_PREFIX": "1"]
        XCTAssertNil(refusal(on))
        XCTAssertEqual(refusal(on, media: true), .unsupportedLayout)
        XCTAssertEqual(refusal(["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_MIMO_COMPLETE_PREFIX": "1"]),
            .configDisabled)
    }

    func testBothNumericsScopesInvalidateWithoutSessionNamespace() throws {
        func identity(slot: String, process: String, source: String = "revision-a") throws -> CBv2CompleteCheckpointIdentity {
            try XCTUnwrap(PrefixCachePolicy.completeCheckpointIdentity(
                modelAggregateHash: MiMoPrefixStoreTestSupport.identity.modelAggregateHash,
                promptContractID: MiMoPrefixStoreTestSupport.identity.promptContractID,
                binaryHash: String(repeating: "c", count: 64), loadedMetallibHash: String(repeating: "d", count: 64),
                osVersion: "test", mtpConfig: .init(enabled: false), assistantCodecID: nil,
                environment: ["DARKBLOOM_MIMO_COMPLETE_PREFIX": slot],
                processEnvironment: ["DARKBLOOM_MIMO_NAX_GATHER": process],
                additionalNumerics: ["modelType": "mimo_v2", "sourceRevision": source],
                nativeModelType: "mimo_v2"))
        }
        let baseline = try identity(slot: "1", process: "0")
        XCTAssertEqual(baseline, try identity(slot: "1", process: "0"))
        XCTAssertNotEqual(baseline.numericsFingerprint, try identity(slot: "0", process: "0").numericsFingerprint)
        XCTAssertNotEqual(baseline.numericsFingerprint, try identity(slot: "1", process: "1").numericsFingerprint)
        XCTAssertNotEqual(baseline.numericsFingerprint,
            try identity(slot: "1", process: "0", source: "revision-b").numericsFingerprint)
    }

    func testUnboundOwnerRequiresActualCloseJoinBeforeZeroChargeRetirement() async throws {
        let budget = MiMoPrefixStoreTestSupport.budget()
        let layout = CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout
        let store = try MiMoPrefixStoreTestSupport.store(budget: budget, layout: layout)
        let owner = MiMoV26NativePrefixResources(transactionID: UUID(), sessionID: UUID(), budget: budget,
            identity: store.identity, backendLayout: layout)
        try owner.install(store)
        XCTAssertThrowsError(try owner.retireUnusedOwner())
        XCTAssertNotNil(owner.processOwner.snapshot())
        owner.close()
        XCTAssertTrue(store.isClosed)
        XCTAssertThrowsError(try owner.retireUnusedOwner(), "close alone is not the actual IO join")
        await owner.closeAndWait()
        try owner.retireUnusedOwner()
        XCTAssertNil(owner.processOwner.snapshot())
        XCTAssertTrue(owner.snapshot().ownerRetired)
        try FileManager.default.removeItem(at: store.config.dedicatedRoot)
    }

    func testUnboundOwnerCannotRefundRealOutstandingPromise() async throws {
        let budget = MiMoPrefixStoreTestSupport.budget()
        let owner = MiMoV26NativePrefixResources(transactionID: UUID(), sessionID: UUID(), budget: budget,
            identity: MiMoPrefixStoreTestSupport.identity,
            backendLayout: CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout)
        try owner.processOwner.replaceCharge(4096) // real logical C, NO claimed materialization
        await owner.closeAndWait()
        XCTAssertThrowsError(try owner.retireUnusedOwner())
        XCTAssertEqual(owner.processOwner.snapshot()?.chargedBytes, 4096)
        XCTAssertFalse(owner.snapshot().ownerRetired)
        // Host-only promise created by this test: no array or native work exists.
        try owner.processOwner.replaceCharge(0)
        try owner.retireUnusedOwner()
        XCTAssertNil(owner.processOwner.snapshot())
    }

    func testForeignBudgetAndLayoutDoNotConsumeOrCloseAnotherStore() async throws {
        let a = MiMoPrefixStoreTestSupport.budget(), b = MiMoPrefixStoreTestSupport.budget()
        let layout = CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout
        let store = try MiMoPrefixStoreTestSupport.store(budget: b, layout: layout)
        let owner = MiMoV26NativePrefixResources(transactionID: UUID(), sessionID: UUID(), budget: a,
            identity: store.identity, backendLayout: layout)
        XCTAssertThrowsError(try owner.install(store))
        XCTAssertFalse(store.isClosed)
        XCTAssertFalse(owner.snapshot().hasStore)
        let wrongLayout = MiMoV26NativePrefixResources(transactionID: UUID(), sessionID: UUID(), budget: b,
            identity: store.identity, backendLayout: CBv2CompleteCheckpointManifest.contiguousAsymmetricMTPLayout)
        XCTAssertThrowsError(try wrongLayout.install(store))
        XCTAssertFalse(store.isClosed)
        await owner.closeAndWait(); try owner.retireUnusedOwner()
        await wrongLayout.closeAndWait(); try wrongLayout.retireUnusedOwner()
        await store.closeAndWait()
        try FileManager.default.removeItem(at: store.config.dedicatedRoot)
    }
}
