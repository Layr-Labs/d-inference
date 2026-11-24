import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// `trust_status.coordinator_features`: the provider stops idle-zeroing its
/// published decode rate only while the coordinator advertises
/// `decode_rate_age_decay`. Without it the heartbeat is what it was. Synthetic
/// observations and a scripted engine; no model or GPU is involved. Nothing here
/// changes the process-wide advertisement: heartbeats take a task-local value.
@Suite("Coordinator decode rate decay")
struct CoordinatorDecodeRateDecayTests {
    private func decode(_ tps: Double, at: ContinuousClock.Instant) -> EngineRateObservation {
        EngineRateObservation(phase: "decode", tps: tps, prompt: 1_024, context: 1_024, cache: "cold",
            overlap: .init(contended: true, peakRequests: 4), at: at, postureEpoch: nil, aggregate: true,
            decodeShape: .init(batchRows: 4))
    }

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let decays: Bool
            let message: JSONValue
        }
        let feature: String
        let cases: [Case]
    }

    /// Any JSON value, re-encoded byte for byte enough to feed the decoder.
    private enum JSONValue: Decodable, Encodable {
        case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .object(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }
    }

    @Test("every fixture trust_status decodes, and only an advertised feature turns the provider's idle age off")
    func sharedFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "coordinator_features_wire", withExtension: "json", subdirectory: "Fixtures/Protocol"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.feature == DecodeRateIdleAge.coordinatorDecayFeature)
        #expect(fixture.cases.count == 6)
        for item in fixture.cases {
            let data = try JSONEncoder().encode(item.message)
            guard case .trustStatus(let status) = try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) else {
                Issue.record("\(item.name): expected trust status"); continue
            }
            let advertisement = CoordinatorDecayAdvertisement()
            advertisement.update(features: status.coordinatorFeatures)
            #expect(advertisement.value == item.decays, "\(item.name)")
            #expect(DecodeRateIdleAge.effectiveMaximum(configured: .seconds(1_800),
                coordinatorDecays: advertisement.value) == (item.decays ? nil : .seconds(1_800)), "\(item.name)")
        }
    }

    @Test("a trust_status without the field re-encodes without it; with it, the list round-trips")
    func wireShape() throws {
        let legacy = Data(#"{"type":"trust_status","trust_level":"hardware","status":"online"}"#.utf8)
        guard case .trustStatus(let old) = try ProviderProtocolCodec.decodeCoordinatorMessage(from: legacy) else {
            Issue.record("expected trust status"); return
        }
        #expect(old.coordinatorFeatures == nil)
        let reencoded = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CoordinatorMessage.trustStatus(old))) as? [String: Any])
        #expect(reencoded["coordinator_features"] == nil)
        let current = CoordinatorMessage.TrustStatus(trustLevel: "hardware", status: "online",
            coordinatorFeatures: [DecodeRateIdleAge.coordinatorDecayFeature])
        let encoded = try JSONEncoder().encode(CoordinatorMessage.trustStatus(current))
        #expect(try JSONDecoder().decode(CoordinatorMessage.self, from: encoded) == .trustStatus(current))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["coordinator_features"] as? [String] == ["decode_rate_age_decay"])
    }

    @Test("the advertisement follows each trust_status and clears on reset")
    func advertisementLifecycle() {
        let advertisement = CoordinatorDecayAdvertisement()
        #expect(!advertisement.value)
        advertisement.update(features: ["decode_rate_age_decay"])
        #expect(advertisement.value)
        advertisement.update(features: nil)
        #expect(!advertisement.value, "a later trust_status without the field restores the idle age")
        advertisement.update(features: ["decode_rate_age_decay"])
        advertisement.reset()
        #expect(!advertisement.value, "a disconnect restores the idle age")
        #expect(DecodeRateIdleAge.effectiveMaximum(configured: nil, coordinatorDecays: false) == nil)
        #expect(DecodeRateIdleAge.effectiveMaximum(configured: .seconds(900), coordinatorDecays: false) == .seconds(900))
    }

    @Test("without the feature an idle stale slot's heartbeat is byte for byte what it was; with it the rate and its age stay")
    func heartbeatBytes() async throws {
        let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], admissionFixes: true)
        let start = ContinuousClock.now
        await bridge.applyRateObservation(decode(16, at: start), requestID: "stacked", calibration: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for offset in [60, 1_801, 7_200] {
            let now = start + .seconds(offset)
            // The process-wide value is false in tests: no coordinator is connected.
            let process = try encoder.encode(await bridge.backendSlotCapacity(now: now))
            let absent = try await DecodeRateIdleAge.$coordinatorDecaysOverride.withValue(false) {
                try encoder.encode(await bridge.backendSlotCapacity(now: now))
            }
            #expect(process == absent, "offset \(offset)")
            let advertised = try await DecodeRateIdleAge.$coordinatorDecaysOverride.withValue(true) {
                await bridge.backendSlotCapacity(now: now)
            }
            let without = try JSONDecoder().decode(BackendSlotCapacity.self, from: absent)
            #expect(advertised.observedDecodeTps == 16, "offset \(offset)")
            #expect(advertised.observedDecodeTpsAgeMs == Int64(offset) * 1_000, "offset \(offset)")
            if offset > 1_800 {
                #expect(without.observedDecodeTps == 0 && without.observedDecodeTpsAgeMs == nil)
            } else {
                #expect(try encoder.encode(advertised) == absent, "a fresh rate is the same either way")
            }
        }
        await bridge.shutdown()
    }
}
