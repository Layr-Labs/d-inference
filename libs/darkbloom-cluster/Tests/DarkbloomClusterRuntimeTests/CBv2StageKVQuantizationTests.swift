import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// The cluster's stage KV follows main's live KV quantization policy: the launch
// names the precision the owner resolved from the provider's own settings,
// both ranks bind it into their load agreement, and a host prices each request
// at its pool's real bytes per token. Parsing, agreement and pricing here,
// with a real two-rank agreement exchange over local sockets; no model.

@Suite("Stage KV live precision: launch, agreement and pricing (no model)", .serialized)
struct CBv2StageKVQuantizationTests {
    @Test func theLaunchNamesThePrecisionNativeByDefault() throws {
        let key = PagedKVQuantizationPolicy.environmentKey
        #expect(try PagedKVQuantizationSelection.clusterLive([:]) == .native)
        #expect(try PagedKVQuantizationSelection.clusterLive([key: ""]) == .native)
        #expect(try PagedKVQuantizationSelection.clusterLive([key: "balanced"]) == .balanced)
        #expect(try PagedKVQuantizationSelection.clusterLive([key: " K8V4 "]) == .k8v4)
        #expect(try PagedKVQuantizationSelection.clusterLive([key: "int8"]) == .k8v8)
        #expect(try PagedKVQuantizationSelection.clusterLive([key: "off"]) == .native)
        #expect(throws: PagedKVQuantizationPolicy.Failure.invalidSelection("k4v44")) {
            try PagedKVQuantizationSelection.clusterLive([key: "k4v44"])
        }
        // Main's checkpoint precision never selects live storage.
        #expect(try PagedKVQuantizationSelection.clusterLive(
            [PagedKVQuantizationPolicy.checkpointEnvironmentKey: "k8v8"]) == .native)
    }

    @Test func pathsThatCannotKeepPackedRowsRefuseByName() throws {
        try PagedKVQuantizationSelection.native.requireNative("anything", paged: false)
        #expect(throws: PagedKVQuantizationPolicy.Failure.requiresPagedBackend("the GPT-OSS stage storage")) {
            try PagedKVQuantizationSelection.balanced.requireNative("the GPT-OSS stage storage", paged: false)
        }
        do {
            try PagedKVQuantizationSelection.k8v8.requireNative("the phase_split_v1 hand-off")
            Issue.record("a hand-off accepted packed rows")
        } catch let error as ProbeError {
            #expect(error.description.contains("k8v8") && error.description.contains("native live precision"))
        }
    }

    /// The load's agreement digest material for one rank (`QwenResidentRuntime.load`).
    static func agreement(_ selection: PagedKVQuantizationSelection) throws -> String {
        sha256(try canonicalJSONData(["fixture-plan-and-membership"]
            + ClusterStageKVBackendKind.paged.loadAgreementFields + selection.loadAgreementFields))
    }

    @Test func nativeKeepsItsAgreementBytesAndEveryPrecisionIsItsOwnAgreement() throws {
        #expect(PagedKVQuantizationSelection.native.loadAgreementFields.isEmpty)
        let before = sha256(try canonicalJSONData(["fixture-plan-and-membership", "cluster-stage-kv-v1", "paged"]))
        #expect(try Self.agreement(.native) == before)
        let balanced = try #require(PagedKVQuantizationSelection.balanced.configuration)
        #expect(PagedKVQuantizationSelection.balanced.loadAgreementFields
            == ["cluster-stage-kv-quantization-v1", "balanced", balanced.identity])
        let digests = try PagedKVQuantizationSelection.allCases.map(Self.agreement)
        #expect(Set(digests).count == PagedKVQuantizationSelection.allCases.count)
    }

    /// Both ranks run the load's first exchange over real local sockets.
    static func exchange(_ first: PagedKVQuantizationSelection, _ second: PagedKVQuantizationSelection) throws
        -> (Result<String, Error>, Result<String, Error>) {
        let fixture = try ResidualStreamCollectiveFixture()
        func agree(_ collective: Collective, _ selection: PagedKVQuantizationSelection) -> Result<String, Error> {
            Result {
                let fingerprint = try Self.agreement(selection)
                return try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoadIntent(agreementFingerprint: fingerprint) },
                    disagreementMessage: "Resident load membership/source/Plan/mode differs",
                    scope: .session(.loadAgreement, "resident-load-intent"), check: {})
            }
        }
        var rank0: Result<String, Error>?
        let rank1 = try fixture.exchange(send: { rank0 = agree(fixture.first, first) },
            receive: { agree($0, second) })
        return (try #require(rank0), rank1)
    }

    @Test func peersToldDifferentPrecisionsRefuseToLoad() throws {
        let same = try Self.exchange(.balanced, .balanced)
        #expect(try same.0.get() == same.1.get())
        for (first, second) in [(PagedKVQuantizationSelection.native, PagedKVQuantizationSelection.balanced),
                                (.k8v4, .k8v8)] {
            let mismatched = try Self.exchange(first, second)
            for result in [mismatched.0, mismatched.1] {
                #expect(throws: ProbeError.self) { try result.get() }
            }
        }
    }

    @Test func nativePricingIsUnchangedAndPackedPricingIsThePoolsRows() throws {
        for (kvHeads, headDim) in [(2, 64), (4, 256), (8, 128)] {
            for dtype in [DType.bfloat16, .float32] {
                for tokens in [1, 15, 16, 17, 4096, 65_536] {
                    let kinds = Array(repeating: CBv2LayerKind(attention: .full, headDim: headDim, kvHeads: kvHeads,
                        queryHeads: 2 * kvHeads), count: 3)
                    let rows = (tokens + CBv2PagedDefaults.pageSize - 1) / CBv2PagedDefaults.pageSize * CBv2PagedDefaults.pageSize
                    let native = try CBv2StageKVHost.pagedRequestBytes(kinds: kinds, dtype: dtype,
                        maximumTokens: tokens, maximumChunkTokens: 512)
                    // The formula every native host always priced with.
                    #expect(native == 3 * rows * kvHeads * headDim * dtype.size * 2)
                    for selection in [PagedKVQuantizationSelection.balanced, .k8v4, .k8v8] {
                        let format = try #require(selection.configuration)
                        let rate = try format.bytesPerToken(kvHeads: kvHeads, headDim: headDim)
                        let packed = try CBv2StageKVHost.pagedRequestBytes(kinds: kinds, dtype: dtype,
                            quantization: selection, maximumTokens: tokens, maximumChunkTokens: 512)
                        #expect(packed == 3 * rows * rate)
                        #expect(packed < native, "\(selection) \(kvHeads)x\(headDim) \(dtype)")
                    }
                }
            }
        }
    }

    /// Windows of at most the recent band stay native, as main's pool keeps
    /// them; a longer window's ring is packed.
    @Test func slidingRingsArePricedAsThePoolStoresThem() throws {
        let format = try #require(PagedKVQuantizationSelection.balanced.configuration)
        for window in [128, 1024] {
            let kind = CBv2LayerKind(attention: .slidingWindow(window), headDim: 256, kvHeads: 8, queryHeads: 16)
            let residency = CBv2PagedKVResidency(config: PagedKVPoolConfig(capacityBytes: 1, dtype: .bfloat16,
                maxPrefillChunk: 512, nominalMaxSequenceLength: 8192, segmentSizeBytes: CBv2StageKVHost.segmentBytes))
            let rows = try #require(residency.residentRows(layer: kind, tokens: 8192))
            let packed = try CBv2StageKVHost.pagedRequestBytes(kinds: [kind], dtype: .bfloat16,
                quantization: .balanced, maximumTokens: 8192, maximumChunkTokens: 512)
            let packedRate = try format.bytesPerToken(kvHeads: 8, headDim: 256)
            let rate = window <= format.recentTokenCount ? 8 * 512 * 2 : packedRate
            #expect(packed == rows * rate, "window \(window)")
        }
    }
}
