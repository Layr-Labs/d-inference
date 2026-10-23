import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import MLXVLM
@testable import ProviderCore

struct NemotronSuperLocalImageBindingTests {
    private func body(image: String, extras: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID,
            "messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": image]]]]]]
        for (key, item) in extras { value[key] = item }
        return try JSONSerialization.data(withJSONObject: value)
    }

    /// Bounds the request cannot meet anywhere are client faults (400 or
    /// 413), not retryable capacity.
    @Test func encodedHeaderAdmissionIsBoundedBeforeParsing() throws {
        let maximum = NemotronSuperServingPolicy.maximumEncodedBodyBytes
        #expect(try NemotronSuperLocalImageBinding.encodedHeaderQuote(bodyBytes: maximum, templateBytes: 1)
                == UInt64(maximum) * 32 + 4 + 16 * 1024 * 1024)
        #expect(throws: NemotronSuperLocalImageBinding.Failure.bodyTooLarge) {
            try NemotronSuperLocalImageBinding.encodedHeaderQuote(bodyBytes: maximum + 1, templateBytes: 1)
        }
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try NemotronSuperLocalImageBinding.encodedHeaderQuote(bodyBytes: 0, templateBytes: 1)
        }
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try NemotronSuperLocalImageBinding.encodedHeaderQuote(bodyBytes: 1, templateBytes: 1024 * 1024 + 1)
        }
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try NemotronSuperLocalImageBinding.encodedHeaderQuote(bodyBytes: 1, templateBytes: 0)
        }
        #expect(try NemotronSuperLocalImageBinding.encodedHeaderQuote(bodyBytes: 100, templateBytes: 20)
                == 16 * 1024 * 1024 + 3280)
    }

    @Test func encodedBodyRejectsRemoteAndUnsupportedControls() throws {
        for uri in ["https://example.invalid/image.png", "file:///tmp/image.png",
                    "data:image/gif;base64,AA==", "data:image/jpg;base64,AA==", "data:image/png,abc",
                    "data:image/jpeg,abc"] {
            let data = try body(image: uri)
            #expect(throws: NemotronSuperLocalImageBinding.Failure.unsupportedCapability) {
                try NemotronSuperLocalImageBinding.parseEncodedBody(data)
            }
        }
        let unsupported = try body(image: "data:image/png;base64,AA==", extras: ["logprobs": true])
        #expect(throws: NemotronSuperLocalImageBinding.Failure.unsupportedCapability) {
            try NemotronSuperLocalImageBinding.parseEncodedBody(unsupported)
        }
        let parsed = try NemotronSuperLocalImageBinding.parseEncodedBody(
            body(image: "data:image/png;base64,AQID", extras: ["max_tokens": 7, "temperature": 0]))
        #expect(parsed.images == [Data([1, 2, 3])])
        #expect(parsed.request.max_tokens == 7 && parsed.request.temperature == 0)
        #expect(throws: NemotronSuperImageDecode.Failure.unsupportedEncoding) {
            try NemotronSuperLocalImageBinding.encodedPlan(parsed.images, contextLength: 64)
        }
        // The JPEG label is admitted too; content, not the label, then decides.
        let jpegLabel = try NemotronSuperLocalImageBinding.parseEncodedBody(
            body(image: "data:image/jpeg;base64,AQID"))
        #expect(jpegLabel.images == [Data([1, 2, 3])])
        #expect(throws: NemotronSuperImageDecode.Failure.unsupportedEncoding) {
            try NemotronSuperLocalImageBinding.encodedPlan(jpegLabel.images, contextLength: 64)
        }
    }

    @Test func preparationQuoteChargesNormalizedInputsAndFeatures() throws {
        let pixels = MLXArray.zeros([1, 3, 32, 32])
        let quote = try NemotronSuperLocalImageBinding.preparationQuote(
            .init(promptTokens: [1, 18, 18, 2], normalizedImages: [pixels]), contextLength: 64)
        #expect(quote.featureBytes == 2 * 4096 * 4)
        // Features and input (45,056) plus the pinned tower bound for 2x2 patches.
        let expectedBytes: UInt64 = 45_056 + 85_232_640
        #expect(quote.totalBytes == expectedBytes)
    }

    @Test func preparationQuoteRejectsAbsentMediaAndContextOverflow() {
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try NemotronSuperLocalImageBinding.preparationQuote(
                .init(promptTokens: [1, 18], normalizedImages: []), contextLength: 64)
        }
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try NemotronSuperLocalImageBinding.preparationQuote(
                .init(promptTokens: [1, 18], normalizedImages: []), contextLength: 1)
        }
    }

    @Test func preparationQuoteRejectsInvalidTokensAndStorageDType() {
        let integers = MLXArray.zeros([1, 3, 32, 32], dtype: .int32)
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try NemotronSuperLocalImageBinding.preparationQuote(
                .init(promptTokens: [1, 18], normalizedImages: [integers]), contextLength: 64)
        }
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try NemotronSuperLocalImageBinding.preparationQuote(
                .init(promptTokens: [-1, 18], normalizedImages: [integers]), contextLength: 64)
        }
    }

    @Test(.timeLimit(.minutes(2))) func encodedRGBSuccessCancellationAndBusyIsolation() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-encoded-image",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperSyntheticImageTokenizer()), eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let images = try owner.localImageBinding()
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64, options: .ignoreUnknownCharacters))
        let requestBody = try body(image: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=", extras: ["max_tokens": 2, "temperature": 0])
        let baseline = await budget.outstandingReservedBytes()
        let completed = SuperOwnedImageEvents()
        try await images.runEncoded(body: requestBody, templateBytes: template) { event in
            _ = await completed.record(event)
        }
        #expect(await completed.errors.isEmpty)
        #expect(await completed.completions == [2])
        #expect(await budget.outstandingReservedBytes() == baseline)
        let cancelled = SuperOwnedImageEvents()
        do {
            try await images.runEncoded(body: requestBody, templateBytes: template) { event in
                if await cancelled.record(event) {
                    // This callback is an admitted-work latch: both entry points
                    // must reject before admission while the same request is live.
                    await #expect(throws: NemotronSuperLocalImageBinding.Failure.busy) {
                        try await images.runEncoded(body: requestBody, templateBytes: template) { _ in
                            Issue.record("busy encoded request emitted an event")
                        }
                    }
                    await #expect(throws: NemotronSuperLocalImageBinding.Failure.busy) {
                        try await images.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                            input: .init(promptTokens: [], normalizedImages: [])) { _ in
                            Issue.record("busy direct request emitted an event")
                        }
                    }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            Issue.record("cancelled encoded image request returned normally")
        } catch is CancellationError { }
        #expect(await cancelled.chunks > 0)
        #expect(await budget.outstandingReservedBytes() == baseline)
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test(.timeLimit(.minutes(1))) func ownedImagesCancelRetireAndRejectAfterClose() async throws {
        let (installed, construction, residency) = try SuperInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-owned-image",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperSyntheticTokenizer()), eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 64, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let images = try owner.localImageBinding()
        #expect(try owner.localImageBinding() === images)
        let input = NemotronSuperLocalImageBinding.Input(promptTokens: [1, 18, 2],
            normalizedImages: [MLXArray.zeros([1, 1, 4, 4])])
        let before = await budget.outstandingReservedBytes()
        // The real ingress reservation is acquired then refunded after the
        // owned task rejects a URL, without touching vision execution.
        let remote = try body(image: "https://example.invalid/image.png")
        await #expect(throws: NemotronSuperLocalImageBinding.Failure.unsupportedCapability) {
            try await images.runEncoded(body: remote, templateBytes: Data([1])) { _ in
                Issue.record("rejected encoded request emitted an event")
            }
        }
        #expect(await budget.outstandingReservedBytes() == before)
        let cancelledEvents = SuperOwnedImageEvents()
        do {
            try await images.run(request: .init(model: NemotronSuperLocalBinding.modelID,
                messages: [], temperature: 0, max_tokens: 32), input: input) { event in
                if await cancelledEvents.record(event) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            let failures = await cancelledEvents.errors
            Issue.record("cancelled image request unexpectedly returned normally: \(failures)")
        } catch is CancellationError { }
        #expect(await cancelledEvents.chunks > 0)
        #expect(await budget.outstandingReservedBytes() == before)
        let completedEvents = SuperOwnedImageEvents()
        try await images.run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 2), input: input) { event in
            _ = await completedEvents.record(event)
        }
        let completedErrors = await completedEvents.errors
        #expect(completedErrors.isEmpty, "owned image errors: \(completedErrors)")
        #expect(await completedEvents.completions == [2])
        #expect(await budget.outstandingReservedBytes() == before)
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        do {
            try await images.run(request: .init(model: NemotronSuperLocalBinding.modelID,
                messages: [], max_tokens: 2), input: input) { _ in }
            Issue.record("closed image owner accepted work")
        } catch NemotronSuperLocalImageBinding.Failure.closed { }
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

private actor SuperOwnedImageEvents {
    var chunks = 0
    var errors: [String] = []
    var completions: [Int] = []
    func record(_ event: GenerationEvent) -> Bool {
        switch event {
        case .chunk: chunks += 1; return chunks == 1
        case .info(_, let count, _, _): completions.append(count)
        case .error(let message): errors.append(message)
        case .terminal(_, let message, _, _): errors.append(message)
        }
        return false
    }
}

/// Scripted tokenizer only. The test exercises verified template identity and
/// placeholder expansion; it does not claim Jinja/tokenizer parity.
struct SuperSyntheticImageTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 18, 2] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { String(repeating: "x", count: tokenIds.count) }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { "x" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 18, 2] }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] { [1, 18, 2] }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 18, 2] }
}

// Exact NVIDIA pinned chat_template.jinja fixture (Apache-2.0), revision
// 7d4bc747b6bdc2cff64c58d65da0d08dd9caa25c; decoded SHA-256 checked by production contract.
let superImagePinnedTemplateBase64 = """
eyUgbWFjcm8gcmVuZGVyX2V4dHJhX2tleXMoanNvbl9kaWN0LCBoYW5kbGVkX2tleXMpICV9CiAgICB7JS0gaWYganNvbl9kaWN0
IGlzIG1hcHBpbmcgJX0KICAgICAgICB7JS0gZm9yIGpzb25fa2V5IGluIGpzb25fZGljdCBpZiBqc29uX2tleSBub3QgaW4gaGFu
ZGxlZF9rZXlzICV9CiAgICAgICAgICAgIHslLSBpZiBqc29uX2RpY3RbanNvbl9rZXldIGlzIG1hcHBpbmcgb3IgKGpzb25fZGlj
dFtqc29uX2tleV0gaXMgc2VxdWVuY2UgYW5kIGpzb25fZGljdFtqc29uX2tleV0gaXMgbm90IHN0cmluZykgJX0KICAgICAgICAg
ICAgICAgIHt7LSAnXG48JyB+IGpzb25fa2V5IH4gJz4nIH4gKGpzb25fZGljdFtqc29uX2tleV0gfCB0b2pzb24gfCBzYWZlKSB+
ICc8LycgfiBqc29uX2tleSB+ICc+JyB9fQogICAgICAgICAgICB7JS0gZWxzZSAlfQogICAgICAgICAgICAgICAge3stJ1xuPCcg
fiBqc29uX2tleSB+ICc+JyB+IChqc29uX2RpY3RbanNvbl9rZXldIHwgc3RyaW5nKSB+ICc8LycgfiBqc29uX2tleSB+ICc+JyB9
fQogICAgICAgICAgICB7JS0gZW5kaWYgJX0KICAgICAgICB7JS0gZW5kZm9yICV9CiAgICB7JS0gZW5kaWYgJX0KeyUgZW5kbWFj
cm8gJX0KeyUtIG1hY3JvIHJlbmRlcl9jb250ZW50KGNvbnRlbnQpIC0lfQogICAgeyUtIGlmIGNvbnRlbnQgaXMgbm9uZSAtJX0K
ICAgICAgICB7ey0gJycgLX19CiAgICB7JS0gZWxpZiBjb250ZW50IGlzIHN0cmluZyAtJX0KICAgICAgICB7ey0gY29udGVudCB8
IHN0cmluZyAtfX0KICAgIHslLSBlbHNlIC0lfQogICAgICAgIHslLSBzZXQgdGV4dF9ucyA9IG5hbWVzcGFjZSh2YWw9JycpIC0l
fQogICAgICAgIHslLSBzZXQgY291bnRlcnMgPSBuYW1lc3BhY2UoaW1hZ2VzPTAsIHZpZGVvcz0wKSAtJX0KICAgICAgICB7JS0g
Zm9yIHBhcnQgaW4gY29udGVudCAtJX0KICAgICAgICAgICAgeyUtIGlmIHBhcnRbJ3R5cGUnXSA9PSAnaW1hZ2UnIG9yIHBhcnRb
J3R5cGUnXSA9PSAnaW1hZ2VfdXJsJyBvciBwYXJ0Wyd0eXBlJ10gPT0gJ2lucHV0X2ltYWdlJyAtJX0KICAgICAgICAgICAgICAg
IHslLSBzZXQgY291bnRlcnMuaW1hZ2VzID0gY291bnRlcnMuaW1hZ2VzICsgMSAtJX0KICAgICAgICAgICAgeyUtIGVsaWYgcGFy
dFsndHlwZSddID09ICd2aWRlbycgb3IgcGFydFsndHlwZSddID09ICd2aWRlb191cmwnIG9yIHBhcnRbJ3R5cGUnXSA9PSAnaW5w
dXRfdmlkZW8nIC0lfQogICAgICAgICAgICAgICAgeyUtIHNldCBjb3VudGVycy52aWRlb3MgPSBjb3VudGVycy52aWRlb3MgKyAx
IC0lfQogICAgICAgICAgICB7JS0gZWxpZiBwYXJ0Wyd0eXBlJ10gPT0gJ3RleHQnIG9yIHBhcnRbJ3R5cGUnXSA9PSAnaW5wdXRf
dGV4dCcgLSV9CiAgICAgICAgICAgICAgICB7JS0gc2V0IHRleHRfbnMudmFsID0gdGV4dF9ucy52YWwgKyAocGFydFsndGV4dCdd
IHwgZGVmYXVsdCgnJywgdHJ1ZSkpIC0lfQogICAgICAgICAgICB7JS0gZW5kaWYgLSV9CiAgICAgICAgeyUtIGVuZGZvciAtJX0K
ICAgICAgICB7JS0gaWYgJzxpbWFnZT4nIGluIHRleHRfbnMudmFsIC0lfQogICAgICAgICAgICB7JS0gc2V0IGNvdW50ZXJzLmlt
YWdlcyA9IDAgLSV9CiAgICAgICAgeyUtIGVuZGlmIC0lfQogICAgICAgIHslLSBpZiAnPHZpZGVvPicgaW4gdGV4dF9ucy52YWwg
LSV9CiAgICAgICAgICAgIHslLSBzZXQgY291bnRlcnMudmlkZW9zID0gMCAtJX0KICAgICAgICB7JS0gZW5kaWYgLSV9CiAgICAg
ICAgeyUtIHNldCBjb250ZW50X25zID0gbmFtZXNwYWNlKHZhbD0nJykgLSV9CiAgICAgICAgeyUtIHNldCByZW5kZXJfbnMgPSBu
YW1lc3BhY2UoaW1hZ2VfaW5kZXg9MCwgYWZ0ZXJfdGV4dD1mYWxzZSkgLSV9CiAgICAgICAgeyUtIGZvciBwYXJ0IGluIGNvbnRl
bnQgLSV9CiAgICAgICAgICAgIHslLSBzZXQgc2VwID0gJ1xuJyBpZiByZW5kZXJfbnMuYWZ0ZXJfdGV4dCBhbmQgbm90IGNvbnRl
bnRfbnMudmFsLmVuZHN3aXRoKCdcbicpIGVsc2UgJycgLSV9CiAgICAgICAgICAgIHslLSBpZiBwYXJ0Wyd0eXBlJ10gPT0gJ2lt
YWdlJyBvciBwYXJ0Wyd0eXBlJ10gPT0gJ2ltYWdlX3VybCcgb3IgcGFydFsndHlwZSddID09ICdpbnB1dF9pbWFnZScgLSV9CiAg
ICAgICAgICAgICAgICB7JS0gc2V0IHJlbmRlcl9ucy5pbWFnZV9pbmRleCA9IHJlbmRlcl9ucy5pbWFnZV9pbmRleCArIDEgLSV9
CiAgICAgICAgICAgICAgICB7JS0gaWYgY291bnRlcnMuaW1hZ2VzID4gMCAtJX0KICAgICAgICAgICAgICAgICAgICB7JS0gaWYg
Y291bnRlcnMuaW1hZ2VzID4gMSAtJX0KICAgICAgICAgICAgICAgICAgICAgICAgeyUtIHNldCBjb250ZW50X25zLnZhbCA9IGNv
bnRlbnRfbnMudmFsICsgc2VwCiAgICAgICAgICAgICAgICAgICAgICAgICAgICArICc8aW1hZ2UgJyArIHJlbmRlcl9ucy5pbWFn
ZV9pbmRleHxzdHJpbmcgKyAnPjxpbWFnZT4nIC0lfQogICAgICAgICAgICAgICAgICAgIHslLSBlbHNlIC0lfQogICAgICAgICAg
ICAgICAgICAgICAgICB7JS0gc2V0IGNvbnRlbnRfbnMudmFsID0gY29udGVudF9ucy52YWwgKyBzZXAgKyAnPGltYWdlPicgLSV9
CiAgICAgICAgICAgICAgICAgICAgeyUtIGVuZGlmIC0lfQogICAgICAgICAgICAgICAgICAgIHslLSBzZXQgcmVuZGVyX25zLmFm
dGVyX3RleHQgPSBmYWxzZSAtJX0KICAgICAgICAgICAgICAgIHslLSBlbmRpZiAtJX0KICAgICAgICAgICAgeyUtIGVsaWYgcGFy
dFsndHlwZSddID09ICd2aWRlbycgb3IgcGFydFsndHlwZSddID09ICd2aWRlb191cmwnIG9yIHBhcnRbJ3R5cGUnXSA9PSAnaW5w
dXRfdmlkZW8nIC0lfQogICAgICAgICAgICAgICAgeyUtIGlmIGNvdW50ZXJzLnZpZGVvcyA+IDAgLSV9CiAgICAgICAgICAgICAg
ICAgICAgeyUtIHNldCBjb250ZW50X25zLnZhbCA9IGNvbnRlbnRfbnMudmFsICsgc2VwICsgJzx2aWRlbz4nIC0lfQogICAgICAg
ICAgICAgICAgICAgIHslLSBzZXQgcmVuZGVyX25zLmFmdGVyX3RleHQgPSBmYWxzZSAtJX0KICAgICAgICAgICAgICAgIHslLSBl
bmRpZiAtJX0KICAgICAgICAgICAgeyUtIGVsaWYgcGFydFsndHlwZSddID09ICd0ZXh0JyBvciBwYXJ0Wyd0eXBlJ10gPT0gJ2lu
cHV0X3RleHQnIC0lfQogICAgICAgICAgICAgICAgeyUtIHNldCBjb250ZW50X25zLnZhbCA9IGNvbnRlbnRfbnMudmFsICsgKHBh
cnRbJ3RleHQnXSB8IGRlZmF1bHQoJycsIHRydWUpKSAtJX0KICAgICAgICAgICAgICAgIHslLSBpZiBwYXJ0Wyd0ZXh0J10gfCBk
ZWZhdWx0KCcnLCB0cnVlKSAtJX0KICAgICAgICAgICAgICAgICAgICB7JS0gc2V0IHJlbmRlcl9ucy5hZnRlcl90ZXh0ID0gdHJ1
ZSAtJX0KICAgICAgICAgICAgICAgIHslLSBlbmRpZiAtJX0KICAgICAgICAgICAgeyUtIGVuZGlmIC0lfQogICAgICAgIHslLSBl
bmRmb3IgLSV9CiAgICAgICAge3stIGNvbnRlbnRfbnMudmFsIC19fQogICAgeyUtIGVuZGlmIC0lfQp7JS0gZW5kbWFjcm8gJX0K
eyUtIHNldCBlbmFibGVfdGhpbmtpbmcgPSBlbmFibGVfdGhpbmtpbmcgaWYgZW5hYmxlX3RoaW5raW5nIGlzIGRlZmluZWQgZWxz
ZSBUcnVlICV9CnslLSBzZXQgbWVkaXVtX2VmZm9ydCA9IG1lZGl1bV9lZmZvcnQgaWYgbWVkaXVtX2VmZm9ydCBpcyBkZWZpbmVk
IGVsc2UgRmFsc2UgJX0KeyUtIHNldCB0cnVuY2F0ZV9oaXN0b3J5X3RoaW5raW5nID0gdHJ1bmNhdGVfaGlzdG9yeV90aGlua2lu
ZyBpZiB0cnVuY2F0ZV9oaXN0b3J5X3RoaW5raW5nIGlzIGRlZmluZWQgZWxzZSBUcnVlICV9CnslLSBzZXQgbnMgPSBuYW1lc3Bh
Y2UobGFzdF91c2VyX2lkeCA9IC0xKSAlfQp7JS0gc2V0IGxvb3BfbWVzc2FnZXMgPSBtZXNzYWdlcyAlfQp7JS0gZm9yIG0gaW4g
bG9vcF9tZXNzYWdlcyAlfQogIHslLSBpZiBtWyJyb2xlIl0gPT0gInVzZXIiICV9CiAgICB7JS0gc2V0IG5zLmxhc3RfdXNlcl9p
ZHggPSBsb29wLmluZGV4MCAlfQogIHslLSBlbmRpZiAlfQp7JS0gZW5kZm9yICV9CnslLSBpZiBtZXNzYWdlc1swXVsicm9sZSJd
ID09ICJzeXN0ZW0iICV9CiAgICB7JS0gc2V0IHN5c3RlbV9tZXNzYWdlID0gbWVzc2FnZXNbMF1bImNvbnRlbnQiXSAlfQogICAg
eyUtIHNldCBsb29wX21lc3NhZ2VzID0gbWVzc2FnZXNbMTpdICV9CnslLSBlbHNlICV9CiAgICB7JS0gc2V0IHN5c3RlbV9tZXNz
YWdlID0gIiIgJX0KICAgIHslLSBzZXQgbG9vcF9tZXNzYWdlcyA9IG1lc3NhZ2VzICV9CnslLSBlbmRpZiAlfQp7JS0gaWYgbm90
IHRvb2xzIGlzIGRlZmluZWQgJX0KICAgIHslLSBzZXQgdG9vbHMgPSBbXSAlfQp7JS0gZW5kaWYgJX0KeyUtIHNldCBucyA9IG5h
bWVzcGFjZShsYXN0X3VzZXJfaWR4ID0gLTEpICV9CnslLSBmb3IgbSBpbiBsb29wX21lc3NhZ2VzICV9CiAgeyUtIGlmIG1bInJv
bGUiXSA9PSAidXNlciIgJX0KICAgIHslLSBzZXQgbnMubGFzdF91c2VyX2lkeCA9IGxvb3AuaW5kZXgwICV9CiAgeyUtIGVuZGlm
ICV9CnslLSBlbmRmb3IgJX0KeyUtIGlmIHN5c3RlbV9tZXNzYWdlIGlzIGRlZmluZWQgJX0KICAgIHt7LSAiPHxpbV9zdGFydHw+
c3lzdGVtXG4iIH4gcmVuZGVyX2NvbnRlbnQoc3lzdGVtX21lc3NhZ2UpIH19CnslLSBlbHNlICV9CiAgICB7JS0gaWYgdG9vbHMg
aXMgaXRlcmFibGUgYW5kIHRvb2xzIHwgbGVuZ3RoID4gMCAlfQogICAgICAgIHt7LSAiPHxpbV9zdGFydHw+c3lzdGVtXG4iIH19
CiAgICB7JS0gZW5kaWYgJX0KeyUtIGVuZGlmICV9CnslLSBpZiB0b29scyBpcyBpdGVyYWJsZSBhbmQgdG9vbHMgfCBsZW5ndGgg
PiAwICV9CiAgICB7JS0gaWYgc3lzdGVtX21lc3NhZ2UgaXMgZGVmaW5lZCBhbmQgc3lzdGVtX21lc3NhZ2UgfCBsZW5ndGggPiAw
ICV9CiAgICAgICAge3stICJcblxuIiB9fQogICAgeyUtIGVuZGlmICV9CiAgICB7ey0gIiMgVG9vbHNcblxuWW91IGhhdmUgYWNj
ZXNzIHRvIHRoZSBmb2xsb3dpbmcgZnVuY3Rpb25zOlxuXG4iIH19CiAgICB7ey0gIjx0b29scz4iIH19CiAgICB7JS0gZm9yIHRv
b2wgaW4gdG9vbHMgJX0KICAgICAgICB7JS0gaWYgdG9vbC5mdW5jdGlvbiBpcyBkZWZpbmVkICV9CiAgICAgICAgICAgIHslLSBz
ZXQgdG9vbCA9IHRvb2wuZnVuY3Rpb24gJX0KICAgICAgICB7JS0gZW5kaWYgJX0KICAgICAgICB7ey0gIlxuPGZ1bmN0aW9uPlxu
PG5hbWU+IiB+IHRvb2wubmFtZSB+ICI8L25hbWU+IiB9fQogICAgICAgIHslLSBpZiB0b29sLmRlc2NyaXB0aW9uIGlzIGRlZmlu
ZWQgJX0KICAgICAgICAgICAge3stICdcbjxkZXNjcmlwdGlvbj4nIH4gKHRvb2wuZGVzY3JpcHRpb24gfCB0cmltKSB+ICc8L2Rl
c2NyaXB0aW9uPicgfX0KICAgICAgICB7JS0gZW5kaWYgJX0KICAgICAgICB7ey0gJ1xuPHBhcmFtZXRlcnM+JyB9fQogICAgICAg
IHslLSBpZiB0b29sLnBhcmFtZXRlcnMgaXMgZGVmaW5lZCBhbmQgdG9vbC5wYXJhbWV0ZXJzIGlzIG1hcHBpbmcgYW5kIHRvb2wu
cGFyYW1ldGVycy5wcm9wZXJ0aWVzIGlzIGRlZmluZWQgYW5kIHRvb2wucGFyYW1ldGVycy5wcm9wZXJ0aWVzIGlzIG1hcHBpbmcg
JX0KICAgICAgICAgICAgeyUtIGZvciBwYXJhbV9uYW1lLCBwYXJhbV9maWVsZHMgaW4gdG9vbC5wYXJhbWV0ZXJzLnByb3BlcnRp
ZXN8aXRlbXMgJX0KICAgICAgICAgICAgICAgIHt7LSAnXG48cGFyYW1ldGVyPicgfX0KICAgICAgICAgICAgICAgIHt7LSAnXG48
bmFtZT4nIH4gcGFyYW1fbmFtZSB+ICc8L25hbWU+JyB9fQogICAgICAgICAgICAgICAgeyUtIGlmIHBhcmFtX2ZpZWxkcy50eXBl
IGlzIGRlZmluZWQgJX0KICAgICAgICAgICAgICAgICAgICB7ey0gJ1xuPHR5cGU+JyB+IChwYXJhbV9maWVsZHMudHlwZSB8IHN0
cmluZykgfiAnPC90eXBlPicgfX0KICAgICAgICAgICAgICAgIHslLSBlbmRpZiAlfQogICAgICAgICAgICAgICAgeyUtIGlmIHBh
cmFtX2ZpZWxkcy5kZXNjcmlwdGlvbiBpcyBkZWZpbmVkICV9CiAgICAgICAgICAgICAgICAgICAge3stICdcbjxkZXNjcmlwdGlv
bj4nIH4gKHBhcmFtX2ZpZWxkcy5kZXNjcmlwdGlvbiB8IHRyaW0pIH4gJzwvZGVzY3JpcHRpb24+JyB9fQogICAgICAgICAgICAg
ICAgeyUtIGVuZGlmICV9CiAgICAgICAgICAgICAgICB7JS0gaWYgcGFyYW1fZmllbGRzLmVudW0gaXMgZGVmaW5lZCAlfQogICAg
ICAgICAgICAgICAgICAgIHt7LSAnXG48ZW51bT4nIH4gKHBhcmFtX2ZpZWxkcy5lbnVtIHwgdG9qc29uIHwgc2FmZSkgfiAnPC9l
bnVtPicgfX0KICAgICAgICAgICAgICAgIHslLSBlbmRpZiAlfQogICAgICAgICAgICAgICAgeyUtIHNldCBoYW5kbGVkX2tleXMg
PSBbJ25hbWUnLCAndHlwZScsICdkZXNjcmlwdGlvbicsICdlbnVtJ10gJX0KICAgICAgICAgICAgICAgIHt7LSByZW5kZXJfZXh0
cmFfa2V5cyhwYXJhbV9maWVsZHMsIGhhbmRsZWRfa2V5cykgfX0KICAgICAgICAgICAgICAgIHt7LSAnXG48L3BhcmFtZXRlcj4n
IH19CiAgICAgICAgICAgIHslLSBlbmRmb3IgJX0KICAgICAgICB7JS0gZW5kaWYgJX0KICAgICAgICB7JSBzZXQgaGFuZGxlZF9r
ZXlzID0gWyd0eXBlJywgJ3Byb3BlcnRpZXMnLCAncmVxdWlyZWQnXSAlfQogICAgICAgIHt7LSByZW5kZXJfZXh0cmFfa2V5cyh0
b29sLnBhcmFtZXRlcnMsIGhhbmRsZWRfa2V5cykgfX0KICAgICAgICB7JS0gaWYgdG9vbC5wYXJhbWV0ZXJzIGlzIGRlZmluZWQg
YW5kIHRvb2wucGFyYW1ldGVycy5yZXF1aXJlZCBpcyBkZWZpbmVkICV9CiAgICAgICAgICAgIHt7LSAnXG48cmVxdWlyZWQ+JyB+
ICh0b29sLnBhcmFtZXRlcnMucmVxdWlyZWQgfCB0b2pzb24gfCBzYWZlKSB+ICc8L3JlcXVpcmVkPicgfX0KICAgICAgICB7JS0g
ZW5kaWYgJX0KICAgICAgICB7ey0gJ1xuPC9wYXJhbWV0ZXJzPicgfX0KICAgICAgICB7JS0gc2V0IGhhbmRsZWRfa2V5cyA9IFsn
dHlwZScsICduYW1lJywgJ2Rlc2NyaXB0aW9uJywgJ3BhcmFtZXRlcnMnXSAlfQogICAgICAgIHt7LSByZW5kZXJfZXh0cmFfa2V5
cyh0b29sLCBoYW5kbGVkX2tleXMpIH19CiAgICAgICAge3stICdcbjwvZnVuY3Rpb24+JyB9fQogICAgeyUtIGVuZGZvciAlfQog
ICAge3stICJcbjwvdG9vbHM+IiB9fQogICAge3stICdcblxuSWYgeW91IGNob29zZSB0byBjYWxsIGEgZnVuY3Rpb24gT05MWSBy
ZXBseSBpbiB0aGUgZm9sbG93aW5nIGZvcm1hdCB3aXRoIE5PIHN1ZmZpeDpcblxuPHRvb2xfY2FsbD5cbjxmdW5jdGlvbj1leGFt
cGxlX2Z1bmN0aW9uX25hbWU+XG48cGFyYW1ldGVyPWV4YW1wbGVfcGFyYW1ldGVyXzE+XG52YWx1ZV8xXG48L3BhcmFtZXRlcj5c
bjxwYXJhbWV0ZXI9ZXhhbXBsZV9wYXJhbWV0ZXJfMj5cblRoaXMgaXMgdGhlIHZhbHVlIGZvciB0aGUgc2Vjb25kIHBhcmFtZXRl
clxudGhhdCBjYW4gc3BhblxubXVsdGlwbGUgbGluZXNcbjwvcGFyYW1ldGVyPlxuPC9mdW5jdGlvbj5cbjwvdG9vbF9jYWxsPlxu
XG48SU1QT1JUQU5UPlxuUmVtaW5kZXI6XG4tIEZ1bmN0aW9uIGNhbGxzIE1VU1QgZm9sbG93IHRoZSBzcGVjaWZpZWQgZm9ybWF0
OiBhbiBpbm5lciA8ZnVuY3Rpb249Li4uPjwvZnVuY3Rpb24+IGJsb2NrIG11c3QgYmUgbmVzdGVkIHdpdGhpbiA8dG9vbF9jYWxs
PjwvdG9vbF9jYWxsPiBYTUwgdGFnc1xuLSBSZXF1aXJlZCBwYXJhbWV0ZXJzIE1VU1QgYmUgc3BlY2lmaWVkXG4tIFlvdSBtYXkg
cHJvdmlkZSBvcHRpb25hbCByZWFzb25pbmcgZm9yIHlvdXIgZnVuY3Rpb24gY2FsbCBpbiBuYXR1cmFsIGxhbmd1YWdlIEJFRk9S
RSB0aGUgZnVuY3Rpb24gY2FsbCwgYnV0IE5PVCBhZnRlclxuLSBJZiB0aGVyZSBpcyBubyBmdW5jdGlvbiBjYWxsIGF2YWlsYWJs
ZSwgYW5zd2VyIHRoZSBxdWVzdGlvbiBsaWtlIG5vcm1hbCB3aXRoIHlvdXIgY3VycmVudCBrbm93bGVkZ2UgYW5kIGRvIG5vdCB0
ZWxsIHRoZSB1c2VyIGFib3V0IGZ1bmN0aW9uIGNhbGxzXG48L0lNUE9SVEFOVD4nIH19CnslLSBlbmRpZiAlfQp7JS0gaWYgc3lz
dGVtX21lc3NhZ2UgaXMgZGVmaW5lZCAlfQogICAge3stICc8fGltX2VuZHw+XG4nIH19CnslLSBlbHNlICV9CiAgICB7JS0gaWYg
dG9vbHMgaXMgaXRlcmFibGUgYW5kIHRvb2xzIHwgbGVuZ3RoID4gMCAlfQogICAgICAgIHt7LSAnPHxpbV9lbmR8PlxuJyB9fQog
ICAgeyUtIGVuZGlmICV9CnslLSBlbmRpZiAlfQp7JS0gZm9yIG1lc3NhZ2UgaW4gbG9vcF9tZXNzYWdlcyAlfQogICAgeyUtIHNl
dCBjb250ZW50ID0gcmVuZGVyX2NvbnRlbnQobWVzc2FnZS5jb250ZW50IHwgZGVmYXVsdCgnJywgdHJ1ZSkpICV9CiAgICB7JS0g
aWYgbWVzc2FnZS5yb2xlID09ICJhc3Npc3RhbnQiICV9CiAgICAgICAgeyUtIGlmIG1lc3NhZ2UucmVhc29uaW5nX2NvbnRlbnQg
aXMgZGVmaW5lZCBhbmQgbWVzc2FnZS5yZWFzb25pbmdfY29udGVudCBpcyBzdHJpbmcgYW5kIG1lc3NhZ2UucmVhc29uaW5nX2Nv
bnRlbnQgfCB0cmltIHwgbGVuZ3RoID4gMCAlfQogICAgICAgICAgICB7JS0gc2V0IGNvbnRlbnQgPSAiPHRoaW5rPlxuIiB+IG1l
c3NhZ2UucmVhc29uaW5nX2NvbnRlbnQgfiAiPC90aGluaz4iIH4gY29udGVudCAlfQogICAgICAgIHslLSBlbHNlICV9CiAgICAg
ICAgICAgIHslLSBpZiBjb250ZW50IGlzIHN0cmluZyAtJX0KICAgICAgICAgICAgICAgIHslLSBpZiAnPHRoaW5rPicgbm90IGlu
IGNvbnRlbnQgYW5kICc8L3RoaW5rPicgbm90IGluIGNvbnRlbnQgLSV9CiAgICAgICAgICAgICAgICAgICAgeyUtIHNldCBjb250
ZW50ID0gIjx0aGluaz48L3RoaW5rPiIgfiBjb250ZW50IC0lfQogICAgICAgICAgICAgICAgeyUtIGVuZGlmIC0lfQogICAgICAg
ICAgICB7JS0gZW5kaWYgLSV9CiAgICAgICAgeyUtIGVuZGlmICV9CiAgICAgICAgeyUtIGlmIG1lc3NhZ2UudG9vbF9jYWxscyBp
cyBkZWZpbmVkIGFuZCBtZXNzYWdlLnRvb2xfY2FsbHMgaXMgaXRlcmFibGUgYW5kIG1lc3NhZ2UudG9vbF9jYWxscyB8IGxlbmd0
aCA+IDAgJX0KICAgICAgICAgICAge3stICc8fGltX3N0YXJ0fD5hc3Npc3RhbnRcbicgfX0KICAgICAgICAgICAgICAgIHslLSBz
ZXQgaW5jbHVkZV9jb250ZW50ID0gbm90ICh0cnVuY2F0ZV9oaXN0b3J5X3RoaW5raW5nIGFuZCBsb29wLmluZGV4MCA8IG5zLmxh
c3RfdXNlcl9pZHgpICV9CiAgICAgICAgICAgICAgICB7JS0gaWYgY29udGVudCBpcyBzdHJpbmcgYW5kIGNvbnRlbnQgfCB0cmlt
IHwgbGVuZ3RoID4gMCAlfQogICAgICAgICAgICAgICAgICAgIHslLSBpZiBpbmNsdWRlX2NvbnRlbnQgJX0KICAgICAgICAgICAg
ICAgICAgICAgICAge3stIChjb250ZW50IHwgdHJpbSkgfiAnXG4nIC19fQogICAgICAgICAgICAgICAgICAgIHslLSBlbHNlICV9
CiAgICAgICAgICAgICAgICAgICAgICAgIHslLSBzZXQgYyA9IChjb250ZW50IHwgc3RyaW5nKSAlfQogICAgICAgICAgICAgICAg
ICAgICAgICB7JS0gaWYgJzwvdGhpbms+JyBpbiBjICV9CiAgICAgICAgICAgICAgICAgICAgICAgICAgICB7JS0gc2V0IGMgPSBj
LnNwbGl0KCc8L3RoaW5rPicpWy0xXSAlfQogICAgICAgICAgICAgICAgICAgICAgICB7JS0gZWxpZiAnPHRoaW5rPicgaW4gYyAl
fQogICAgICAgICAgICAgICAgICAgICAgICAgICAgeyUtIHNldCBjID0gYy5zcGxpdCgnPHRoaW5rPicpWzBdICV9CiAgICAgICAg
ICAgICAgICAgICAgICAgIHslLSBlbmRpZiAlfQogICAgICAgICAgICAgICAgICAgICAgICB7JS0gc2V0IGMgPSAiPHRoaW5rPjwv
dGhpbms+IiB+IGMgJX0KICAgICAgICAgICAgICAgICAgICAgICAgeyUtIGlmIGMgfCBsZW5ndGggPiAwICV9CiAgICAgICAgICAg
ICAgICAgICAgICAgICAgICB7ey0gYyB+ICdcbicgLX19CiAgICAgICAgICAgICAgICAgICAgICAgIHslLSBlbmRpZiAlfQogICAg
ICAgICAgICAgICAgICAgIHslLSBlbmRpZiAlfQogICAgICAgICAgICAgICAgeyUtIGVsc2UgJX0KICAgICAgICAgICAgICAgICAg
ICB7ey0gIjx0aGluaz48L3RoaW5rPiIgLX19CiAgICAgICAgICAgICAgICB7JS0gZW5kaWYgJX0KICAgICAgICAgICAgICAgIHsl
LSBmb3IgdG9vbF9jYWxsIGluIG1lc3NhZ2UudG9vbF9jYWxscyAlfQogICAgICAgICAgICAgICAgICAgIHslLSBpZiB0b29sX2Nh
bGwuZnVuY3Rpb24gaXMgZGVmaW5lZCAlfQogICAgICAgICAgICAgICAgICAgICAgICB7JS0gc2V0IHRvb2xfY2FsbCA9IHRvb2xf
Y2FsbC5mdW5jdGlvbiAlfQogICAgICAgICAgICAgICAgICAgIHslLSBlbmRpZiAlfQogICAgICAgICAgICAgICAgICAgIHt7LSAn
PHRvb2xfY2FsbD5cbjxmdW5jdGlvbj0nIH4gdG9vbF9jYWxsLm5hbWUgfiAnPlxuJyAtfX0KICAgICAgICAgICAgICAgICAgICAg
ICAgeyUtIGlmIHRvb2xfY2FsbC5hcmd1bWVudHMgaXMgZGVmaW5lZCAlfQogICAgICAgICAgICAgICAgICAgICAgICAgICAgeyUt
IGZvciBhcmdzX25hbWUsIGFyZ3NfdmFsdWUgaW4gdG9vbF9jYWxsLmFyZ3VtZW50c3xpdGVtcyAlfQogICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgIHt7LSAnPHBhcmFtZXRlcj0nIH4gYXJnc19uYW1lIH4gJz5cbicgLX19CiAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIHslLSBzZXQgYXJnc192YWx1ZSA9IGFyZ3NfdmFsdWUgfCB0b2pzb24gfCBzYWZlIGlmIGFyZ3Nf
dmFsdWUgaXMgbWFwcGluZyBvciAoYXJnc192YWx1ZSBpcyBzZXF1ZW5jZSBhbmQgYXJnc192YWx1ZSBpcyBub3Qgc3RyaW5nKSBl
bHNlIGFyZ3NfdmFsdWUgfCBzdHJpbmcgJX0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB7ey0gYXJnc192YWx1ZSB+
ICdcbjwvcGFyYW1ldGVyPlxuJyAtfX0KICAgICAgICAgICAgICAgICAgICAgICAgICAgIHslLSBlbmRmb3IgJX0KICAgICAgICAg
ICAgICAgICAgICAgICAgeyUtIGVuZGlmICV9CiAgICAgICAgICAgICAgICAgICAge3stICc8L2Z1bmN0aW9uPlxuPC90b29sX2Nh
bGw+XG4nIC19fQogICAgICAgICAgICAgICAgeyUtIGVuZGZvciAlfQogICAgICAgICAgICAgICAge3stICc8fGltX2VuZHw+XG4n
IH19CiAgICAgICAgeyUtIGVsc2UgJX0KICAgICAgICAgICAgeyUtIGlmIG5vdCAodHJ1bmNhdGVfaGlzdG9yeV90aGlua2luZyBh
bmQgbG9vcC5pbmRleDAgPCBucy5sYXN0X3VzZXJfaWR4KSAlfQogICAgICAgICAgICAgICAge3stICc8fGltX3N0YXJ0fD5hc3Np
c3RhbnRcbicgfiAoY29udGVudCB8IGRlZmF1bHQoJycsIHRydWUpIHwgc3RyaW5nIHwgdHJpbSkgfiAnPHxpbV9lbmR8PlxuJyB9
fQogICAgICAgICAgICB7JS0gZWxzZSAlfQogICAgICAgICAgICAgICAgeyUtIHNldCBjID0gKGNvbnRlbnQgfCBkZWZhdWx0KCcn
LCB0cnVlKSB8IHN0cmluZykgJX0KICAgICAgICAgICAgICAgIHslLSBpZiAnPHRoaW5rPicgaW4gYyBhbmQgJzwvdGhpbms+JyBp
biBjICV9CiAgICAgICAgICAgICAgICAgICAgeyUtIHNldCBjID0gIjx0aGluaz48L3RoaW5rPiIgfiBjLnNwbGl0KCc8L3RoaW5r
PicpWy0xXSAlfQogICAgICAgICAgICAgICAgeyUtIGVuZGlmICV9CiAgICAgICAgICAgICAgICB7JS0gc2V0IGMgPSBjIHwgdHJp
bSAlfQogICAgICAgICAgICAgICAgeyUtIGlmIGMgfCBsZW5ndGggPiAwICV9CiAgICAgICAgICAgICAgICAgICAge3stICc8fGlt
X3N0YXJ0fD5hc3Npc3RhbnRcbicgfiBjIH4gJzx8aW1fZW5kfD5cbicgfX0KICAgICAgICAgICAgICAgIHslLSBlbHNlICV9CiAg
ICAgICAgICAgICAgICAgICAge3stICc8fGltX3N0YXJ0fD5hc3Npc3RhbnRcbjx8aW1fZW5kfD5cbicgfX0KICAgICAgICAgICAg
ICAgIHslLSBlbmRpZiAlfQogICAgICAgICAgICB7JS0gZW5kaWYgJX0KICAgICAgICB7JS0gZW5kaWYgJX0KICAgIHslLSBlbGlm
IG1lc3NhZ2Uucm9sZSA9PSAidXNlciIgb3IgbWVzc2FnZS5yb2xlID09ICJzeXN0ZW0iICV9CiAgICAgICAge3stICc8fGltX3N0
YXJ0fD4nICsgbWVzc2FnZS5yb2xlICsgJ1xuJyB9fQogICAgICAgIHsjLSBSZW5kZXIgc3RydWN0dXJlZCBpbWFnZS92aWRlbyBj
b250ZW50IGluIGl0cyBvcmlnaW5hbCBvcmRlci4gLSN9CiAgICAgICAgeyUtIGlmIG1lc3NhZ2Uucm9sZSA9PSAidXNlciIgYW5k
IGxvb3AuaW5kZXgwID09IG5zLmxhc3RfdXNlcl9pZHggYW5kIG1lZGl1bV9lZmZvcnQgJX0KICAgICAgICAgICAge3stIGNvbnRl
bnQgKyAnXG5cbntyZWFzb25pbmcgZWZmb3J0OiBlZmZpY2llbnR9JyB9fQogICAgICAgIHslLSBlbHNlICV9CiAgICAgICAgICAg
IHt7LSBjb250ZW50IH19CiAgICAgICAgeyUtIGVuZGlmICV9CiAgICAgICAge3stICc8fGltX2VuZHw+XG4nIH19CiAgICB7JS0g
ZWxpZiBtZXNzYWdlLnJvbGUgPT0gInRvb2wiICV9CiAgICAgICAgeyUtIGlmIGxvb3AucHJldml0ZW0gYW5kIGxvb3AucHJldml0
ZW0ucm9sZSAhPSAidG9vbCIgJX0KICAgICAgICAgICAge3stICc8fGltX3N0YXJ0fD51c2VyXG4nIH19CiAgICAgICAgeyUtIGVu
ZGlmICV9CiAgICAgICAge3stICc8dG9vbF9yZXNwb25zZT5cbicgfX0KICAgICAgICB7ey0gY29udGVudCB9fQogICAgICAgIHt7
LSAnXG48L3Rvb2xfcmVzcG9uc2U+XG4nIH19CiAgICAgICAgeyUtIGlmIG5vdCBsb29wLmxhc3QgYW5kIGxvb3AubmV4dGl0ZW0u
cm9sZSAhPSAidG9vbCIgJX0KICAgICAgICAgICAge3stICc8fGltX2VuZHw+XG4nIH19CiAgICAgICAgeyUtIGVsaWYgbG9vcC5s
YXN0ICV9CiAgICAgICAgICAgIHt7LSAnPHxpbV9lbmR8PlxuJyB9fQogICAgICAgIHslLSBlbmRpZiAlfQogICAgeyUtIGVsc2Ug
JX0KICAgICAgICB7ey0gJzx8aW1fc3RhcnR8PicgfiBtZXNzYWdlLnJvbGUgfiAnXG4nIH4gY29udGVudCB+ICc8fGltX2VuZHw+
XG4nIH19CiAgICB7JS0gZW5kaWYgJX0KeyUtIGVuZGZvciAlfQp7JS0gaWYgYWRkX2dlbmVyYXRpb25fcHJvbXB0ICV9CiAgICB7
JS0gaWYgZW5hYmxlX3RoaW5raW5nICV9CiAgICAgICAge3stICc8fGltX3N0YXJ0fD5hc3Npc3RhbnRcbjx0aGluaz5cbicgfX0K
ICAgIHslLSBlbHNlICV9CiAgICAgICAge3stICc8fGltX3N0YXJ0fD5hc3Npc3RhbnRcbjx0aGluaz48L3RoaW5rPicgfX0KICAg
IHslLSBlbmRpZiAlfQp7JS0gZW5kaWYgJX0K
"""
