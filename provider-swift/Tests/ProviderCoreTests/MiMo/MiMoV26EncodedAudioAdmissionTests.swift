import Foundation
import MLXVLM
import XCTest
@testable import ProviderCore

/// Metadata and real CPU-only ledger/host-Task tests. No native/model work,
/// measured peak-memory claim, fabricated SDK receipt or generation mock.
final class MiMoV26EncodedAudioAdmissionTests: XCTestCase {
    private typealias Part = [String: any Sendable]
    private let slack: UInt64 = 1 << 20

    private func wave(junkBytes: Int) -> Data {
        func u16(_ x: UInt16) -> [UInt8] {
            [UInt8(truncatingIfNeeded:x),UInt8(truncatingIfNeeded:x >> 8)]
        }
        func u32(_ x: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded:x),UInt8(truncatingIfNeeded:x >> 8),
             UInt8(truncatingIfNeeded:x >> 16),UInt8(truncatingIfNeeded:x >> 24)]
        }
        // Exact classic mono24k PCM16 layout:54+J bytes, ONE sample. J is even.
        var data = Data("RIFF".utf8)
        data.append(contentsOf:u32(UInt32(46+junkBytes)))
        data.append(contentsOf:Array("WAVEfmt ".utf8)+u32(16))
        data.append(contentsOf:u16(1)+u16(1)+u32(24000)+u32(48000)+u16(2)+u16(16))
        data.append(contentsOf:Array("JUNK".utf8)+u32(UInt32(junkBytes)))
        data.append(Data(repeating:0,count:junkBytes))
        data.append(contentsOf:Array("data".utf8)+u32(2)+u16(1))
        return data
    }
    private func audio(_ payload: String) -> Part {
        ["type":"input_audio","input_audio":["data":payload,"format":"wav"]]
    }
    private func policy(_ maximumBytes: UInt64) throws -> MiMoV26ServingLoad.DecodedMediaPolicy {
        try .init(limits:.init(maximumMedia:4,maximumVideoFrames:4,maximumPromptTokens:2048,
            maximumMetadataBytes:65536,maximumMetadataNodes:10000,maximumMetadataDepth:32,
            pixels:.init(maximumInputElements:100000,maximumOutputElements:100000,maximumWorkingBytes:1 << 20),
            vision:.init(maximumPatches:256,maximumAttentionScoreElements:131072),
            audio:.init(maximumClips:2,maximumChannels:1,maximumSampleRate:24000,
                maximumInputSamples:2,maximumResampledSamples:2,maximumResampleCoefficients:100000,
                maximumMelFrames:256,maximumSegments:4,maximumPaddedMelFrames:256,
                maximumWorkingElements:64_000_000,frontendFrameBlockSize:8,rvqTileFrames:8),
            audioPatch:.init(maximumClips:2,maximumFrames:256,maximumPatches:64,maximumWorkingElements:16_000_000)),
            maximumReservationBytes:maximumBytes,additionalSystemReserveBytes:1)
    }
    private func plan(_ parts: [Part], maximumBytes: UInt64) throws -> MiMoV26EncodedMediaIngress.Plan {
        let normalized = ProviderPromptContractPipeline.NormalizedInput(
            messages:[["role":"user","content":parts]],tools:nil,additionalContext:nil)
        return try MiMoV26EncodedMediaIngress.plan(normalized:normalized,controls:.init(),
            maximumOutputTokens:2,policy:policy(maximumBytes),allowAudio:true)
    }
    private func ledger(headroom: UInt64) -> ProcessMemoryLedger {
        // Explicit test-only CPU metadata usage. Does not lower production floors.
        ProcessMemoryLedger(policy:.init(epoch:1,capBytes:headroom+1,reserveBytes:1),
            readUsage:{ .init(activeBytes:0,cacheBytes:0,systemAvailableBytes:UInt64.max) })
    }

    func testLargeJUNKSmallFrameWaveRefusesOldAllowanceBeforeDecode() throws {
        let bytes = wave(junkBytes:6 << 20)
        XCTAssertEqual(bytes.count,(6 << 20)+54)
        let inspected = try MiMoV26EncodedAudioDecoder.inspect(bytes,
            limits:.init(maximumEncodedBytes:8 << 20,maximumFrames:1,maximumWorkingBytes:1028))
        XCTAssertEqual(inspected.frameCount,1)
        XCTAssertEqual(inspected.decodedByteBound,1028) // header-only; no Float allocation
        let payload = bytes.base64EncodedString()
        let uriBytes = UInt64(payload.utf8.count)+22
        // Independent known normalized shape:6 outer nodes +9 audio nodes.
        let table: UInt64 = 15*128+16384
        let oldInitial = 3*uriBytes+table+slack
        let corrected = oldInitial+uriBytes
        XCTAssertThrowsError(try plan([audio(payload)],maximumBytes:oldInitial)) {
            XCTAssertEqual($0 as? MiMoV26MultimodalError,.reservationRejected)
        }
        let funded = try plan([audio(payload)],maximumBytes:corrected)
        XCTAssertEqual(funded.initialBytes,corrected)
        XCTAssertEqual(funded.hostBytes,2*uriBytes+table)
        XCTAssertEqual(funded.initialBytes-oldInitial,uriBytes)
        // Planning never invokes base64/Data/Float decode. Old code admitted
        // this exact oldInitial cap; a merely changed frame cap cannot fix it.
    }

    private final class CompletionWitness: @unchecked Sendable {
        let lock = NSLock()
        private var ids: [String] = []
        private var hostCompletions = 0
        private var failed = false
        func entered(_ id: String) { lock.withLock { ids.append(id) } }
        func hostCompleted(failed: Bool) {
            lock.withLock { hostCompletions += 1; self.failed = failed }
        }
        var snapshot: ([String],Int,Bool) { lock.withLock { (ids,hostCompletions,failed) } }
    }

    func testRealLedgerAndActualHostJoinKeepExtraShareAcrossPhaseReplacement() async throws {
        let bytes = wave(junkBytes:6 << 20), payload = bytes.base64EncodedString()
        let uriBytes = UInt64(payload.utf8.count)+22, table: UInt64 = 15*128+16384
        let oldInitial = 3*uriBytes+table+slack
        let funded = try plan([audio(payload)],maximumBytes:oldInitial+uriBytes)
        let tight = ledger(headroom:oldInitial)
        XCTAssertThrowsError(try MiMoV26ManagedMediaReservation(initialBytes:funded.initialBytes,
            hostBytes:funded.hostBytes,maximumBytes:funded.initialBytes,
            additionalSystemReserveBytes:1,ledger:tight)) {
            XCTAssertEqual($0 as? MiMoV26MultimodalError,.reservationRejected)
        }
        XCTAssertEqual(tight.snapshot().chargedBytes,0)
        XCTAssertEqual(tight.snapshot().ownerCount,0)

        let actualLedger = ledger(headroom:funded.initialBytes)
        let owner = try MiMoV26ManagedMediaReservation(initialBytes:funded.initialBytes,
            hostBytes:funded.hostBytes,maximumBytes:funded.initialBytes,
            additionalSystemReserveBytes:1,ledger:actualLedger)
        XCTAssertEqual(actualLedger.snapshot().chargedBytes,funded.initialBytes)
        // A phase replacement sized using the old host share must not drop
        // the promised URI copy. The genuine owner enforces its host floor.
        let oldHost = uriBytes+table
        XCTAssertThrowsError(try owner.reserveDecodeWorkingBytes(oldHost+1028)) {
            XCTAssertEqual($0 as? MiMoV26MultimodalError,.reservationRejected)
        }
        let lease = NativeLocalConsumerLease(), witness = CompletionWitness()
        let releaseEntered = NativeLocalTaskStartGate(), allowRelease = NativeLocalTaskStartGate()
        defer { allowRelease.open() }
        let release = OneShotRelease(release:{ id in
            witness.entered(id); releaseEntered.open(); await allowRelease.wait()
        },modelId:"audio-host-test",nativeConsumerLease:lease)
        XCTAssertTrue(release.nativeBindingAccepted)
        let retainedBytes = funded.hostBytes+1028
        let preparation = try lease.startPreparation {
            try lease.installMediaHostCompletion(id:owner.id) {
                do {
                    try owner.completeHostOwnership()
                    witness.hostCompleted(failed:false)
                } catch { witness.hostCompleted(failed:true) }
            }
            try owner.retainEncodedOwner(bytes as NSData)
            try owner.reserveDecodeWorkingBytes(retainedBytes)
            owner.abortBeforeNativeAdoption() // CPU metadata/host owner ONLY.
            return true
        }
        _ = try await preparation.value
        XCTAssertEqual(actualLedger.snapshot().chargedBytes,retainedBytes)
        XCTAssertEqual(witness.snapshot.1,0)
        await release.fire()
        await releaseEntered.wait() // the REAL bound release callback is held
        XCTAssertEqual(witness.snapshot.0,["audio-host-test"])
        XCTAssertEqual(witness.snapshot.1,0)
        XCTAssertEqual(actualLedger.snapshot().chargedBytes,retainedBytes)
        allowRelease.open()
        await lease.joinFromOutside() // real Task + callback + host completion
        XCTAssertEqual(witness.snapshot.1,1)
        XCTAssertFalse(witness.snapshot.2)
        XCTAssertEqual(lease.snapshot().phase,.completed)
        XCTAssertEqual(actualLedger.snapshot().chargedBytes,0)
        XCTAssertEqual(actualLedger.snapshot().ownerCount,0)
        // No native adoption/receipt is manufactured; the host completion is
        // the existing post-Task-join callback for actual CPU-only ownership.
    }

    func testImageVideoOnlyKeepOriginalAmounts() throws {
        let image = "data:image/png;base64,AA==", video = "data:video/mp4;base64,AA=="
        let parts: [Part] = [["type":"image_url","image_url":image],["type":"video_url","video_url":video]]
        let encoded = UInt64(image.utf8.count+video.utf8.count)
        //6 outer +5 nodes per visual part,2 media.
        let table: UInt64 = 16*128+2*16384
        let expected = 3*encoded+table+slack
        let actual = try plan(parts,maximumBytes:expected)
        XCTAssertEqual(actual.initialBytes,expected)
        XCTAssertEqual(actual.hostBytes,encoded+table)
    }

    func testMixedAndMultipleAudioSumExactlyOneAdditionalURIShareEach() throws {
        let first = wave(junkBytes:0).base64EncodedString()
        let second = wave(junkBytes:2).base64EncodedString()
        let image = "data:image/png;base64,AA==", video = "data:video/mp4;base64,AA=="
        let parts: [Part] = [audio(first),["type":"image_url","image_url":image],
                             audio(second),["type":"video_url","video_url":video]]
        let audioURIs = UInt64(first.utf8.count+22+second.utf8.count+22)
        let encoded = audioURIs+UInt64(image.utf8.count+video.utf8.count)
        //6 outer +2*9 audio +2*5 visual nodes,4 media.
        let table: UInt64 = 34*128+4*16384
        let expected = 3*encoded+table+slack+audioURIs
        let actual = try plan(parts,maximumBytes:expected)
        XCTAssertEqual(actual.initialBytes,expected)
        XCTAssertEqual(actual.hostBytes,encoded+table+audioURIs)
        XCTAssertThrowsError(try plan(parts,maximumBytes:expected-1))
    }

    func testTransportArithmeticRejectsOverflowWithoutGiantAllocation() throws {
        for (encoded,table,audio) in [
            (UInt64.max,UInt64(0),UInt64(1)),
            (UInt64.max/3+1,UInt64(0),UInt64(0)),
            (UInt64(0),UInt64.max,UInt64(1)),
            (UInt64(0),UInt64.max-slack+1,UInt64(0)),
            (UInt64(0),UInt64(0),UInt64.max)
        ] {
            XCTAssertThrowsError(try MiMoV26EncodedMediaIngress.transportByteBudget(
                encodedBound:encoded,tableBound:table,audioURIBytes:audio)) {
                XCTAssertEqual($0 as? MiMoV26ServingLoadError,.arithmeticOverflow)
            }
        }
        let edge = try MiMoV26EncodedMediaIngress.transportByteBudget(
            encodedBound:0,tableBound:0,audioURIBytes:UInt64.max-slack)
        XCTAssertEqual(edge.hostBytes,UInt64.max-slack)
        XCTAssertEqual(edge.initialBytes,UInt64.max)
    }
}
