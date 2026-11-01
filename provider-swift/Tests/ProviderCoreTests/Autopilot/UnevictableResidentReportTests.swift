import Foundation
import Testing
@testable import ProviderCore

/// A refused load names every resident model it could not evict and why: an
/// Autopilot placement hold (with its expiry), requests in flight, and, for
/// context, an Autopilot adoption outside the selected models. The daemon
/// state carries the same exclusions and the ordinary selection for
/// `darkbloom status`.
@Suite("Refusals name what a load cannot evict", .serialized)
struct UnevictableResidentReportTests {
    private typealias Fixture = UnreclaimableLoadMemoryFixture

    private func adoptAndHoldGLM(_ fixture: Fixture, holdSeconds: Int = 3_600) async throws -> Int64 {
        let loop = fixture.loop
        await loop.activateAutopilotForTesting()
        let status = try #require(await fixture.withModelCache {
            await loop.runAutopilotCommandForTesting(Fixture.adminOperation(holdSeconds: holdSeconds,
                residents: await loop.modelLoadingResidentIDs()))
        })
        #expect(status.status == .succeeded, "\(status.error ?? "")")
        await loop.clearAutopilotControl()
        let hold = try #require(await loop.state.modelAutopilot?.heldModels?.first)
        #expect(hold.modelId == Fixture.glmID)
        return hold.expiresAtMs
    }

    private func superLoadRefusal(_ fixture: Fixture) async throws -> String {
        do {
            try await fixture.loop.ensureModelLoaded(modelId: Fixture.superID,
                                                     revisionDirectory: fixture.superDirectory)
        } catch {
            return try #require(await fixture.loop.modelLoadingLastLoadError()).message
        }
        Issue.record("Super loaded on the scripted machine")
        return ""
    }

    private static func utc(_ ms: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
    }

    private static let glmEntry = "glm-5.3-flash (\(String(format: "%.1f", Double(Fixture.glmBytes) / 1_073_741_824)) GB"

    @Test(.timeLimit(.minutes(1)))
    func superRefusalNamesTheHeldAdoptedModelAndItsExpiry() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let expiresAtMs = try await adoptAndHoldGLM(fixture)

        let message = try await superLoadRefusal(fixture)
        #expect(message.hasPrefix(Fixture.superRefusal(room: "36.8")), "\(message)")
        #expect(message.contains("Not evictable: \(Self.glmEntry): Autopilot hold until \(Self.utc(expiresAtMs))"),
                "\(message)")
        #expect(message.contains("adopted by Autopilot outside the selected models"), "\(message)")
        #expect(!message.contains(Fixture.gemmaID), "Gemma is an eviction candidate: \(message)")
    }

    @Test(.timeLimit(.minutes(1)))
    func superRefusalNamesRequestsInFlightOfASelectedModel() async throws {
        let fixture = try await Fixture.make(glm: .ordinary)
        defer { Task { await fixture.remove() } }
        await fixture.beginGLMRequest()

        let message = try await superLoadRefusal(fixture)
        #expect(message.hasPrefix(Fixture.reportedSuperRefusal), "\(message)")
        #expect(message.contains("Not evictable: \(Self.glmEntry): 1 request in flight)"), "\(message)")
        #expect(!message.contains("Autopilot"), "\(message)")
    }

    /// Nothing is an eviction candidate because the only resident is held,
    /// not because it serves: the refusal must not claim it is serving.
    @Test(.timeLimit(.minutes(1)))
    func aRefusalBlockedOnlyByAHoldDoesNotClaimTheModelIsServing() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory, resident: [Fixture.glmID])
        defer { Task { await fixture.remove() } }
        let expiresAtMs = try await adoptAndHoldGLM(fixture)

        let message = try await superLoadRefusal(fixture)
        #expect(message.hasPrefix("Insufficient memory (53.6 GB of LOAD room, need 83.6 GB)"), "\(message)")
        #expect(!message.contains("actively serving"), "\(message)")
        #expect(message.contains("and no loaded model can be evicted"), "\(message)")
        #expect(message.contains("Autopilot hold until \(Self.utc(expiresAtMs))"), "\(message)")
    }

    /// While every resident serves, the existing wording stays.
    @Test(.timeLimit(.minutes(1)))
    func aRefusalBlockedByServingModelsKeepsItsWording() async throws {
        let fixture = try await Fixture.make(glm: .ordinary, resident: [Fixture.glmID])
        defer { Task { await fixture.remove() } }
        await fixture.beginGLMRequest()

        let message = try await superLoadRefusal(fixture)
        #expect(message.contains("and all loaded models are actively serving"), "\(message)")
        #expect(message.contains("Not evictable: \(Self.glmEntry): 1 request in flight)"), "\(message)")
    }

    /// The ordinary memory gate names the same exclusions.
    @Test(.timeLimit(.minutes(1)))
    func ordinaryLoadRefusalNamesTheHeldModel() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let expiresAtMs = try await adoptAndHoldGLM(fixture)

        var refusal: String?
        do {
            try await fixture.loop.evictUntilAvailable(weightsGb: 80)
        } catch InferenceError.modelLoadFailed(let message) {
            refusal = message
        }
        let message = try #require(refusal)
        #expect(message.contains("even after evicting every idle model"), "\(message)")
        #expect(message.contains("Not evictable: \(Self.glmEntry): Autopilot hold until \(Self.utc(expiresAtMs))"),
                "\(message)")
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0)
    }

    /// Every slot is taken and none can be freed: the slot refusal says why,
    /// and keeps the words the coordinator classifies it by.
    @Test(.timeLimit(.minutes(1)))
    func slotRefusalNamesWhyNoSlotCanBeFreed() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory, maxModelSlots: 2)
        defer { Task { await fixture.remove() } }
        let expiresAtMs = try await adoptAndHoldGLM(fixture)
        await fixture.loop.modelLoadingSetRequest("gemma-request", model: Fixture.gemmaID)

        var refusal: String?
        do {
            try await fixture.loop.ensureModelLoaded(modelId: Fixture.superID, revisionDirectory: fixture.superDirectory)
        } catch InferenceError.invalidModelDirectory(let message) {
            refusal = message
        }
        let message = try #require(refusal)
        #expect(message.hasPrefix("All 2 model slot(s) are active; cannot load '\(Fixture.superID)'"), "\(message)")
        #expect(ProviderLoop.loadErrorStatusCode(for: InferenceError.invalidModelDirectory(message)) == 503)
        #expect(message.contains("gemma-4-26b-qat-4bit (16.8 GB: 1 request in flight)"), "\(message)")
        #expect(message.contains("\(Self.glmEntry): Autopilot hold until \(Self.utc(expiresAtMs))"), "\(message)")
        #expect(fixture.shutdownCalls(Fixture.gemmaID) == 0 && fixture.shutdownCalls(Fixture.glmID) == 0)
    }

    /// The daemon state carries the exclusions, the hold expiry, the adoption
    /// and the ordinary selection (JSON keys, as `status` reads them).
    @Test(.timeLimit(.minutes(1)))
    func daemonStateReportsExclusionsAndTheOrdinarySelection() async throws {
        let fixture = try await Fixture.make(glm: .autopilotInventory)
        defer { Task { await fixture.remove() } }
        let expiresAtMs = try await adoptAndHoldGLM(fixture)
        await fixture.beginGLMRequest()

        let state = try Self.stateJSON(await fixture.loop.currentDaemonState())
        #expect(state["serving_selection"] as? [String] == [Fixture.gemmaID, Fixture.superID])
        let exclusions = try #require(state["eviction_exclusions"] as? [[String: Any]])
        #expect(exclusions.count == 1)
        let glm = try #require(exclusions.first)
        #expect(glm["model"] as? String == Fixture.glmID)
        #expect(glm["reasons"] as? [String] == ["autopilot_hold", "requests_in_flight"])
        #expect((glm["hold_expires_at_ms"] as? NSNumber)?.int64Value == expiresAtMs)
        #expect((glm["requests_in_flight"] as? NSNumber)?.intValue == 1)
        #expect(glm["adopted_by_autopilot"] as? Bool == true)
        #expect(abs(((glm["resident_gb"] as? NSNumber)?.doubleValue ?? 0)
            - Double(Fixture.glmBytes) / 1_073_741_824) < 0.001)

        let ordinary = try await Fixture.make(glm: .ordinary)
        defer { Task { await ordinary.remove() } }
        let ordinaryState = try Self.stateJSON(await ordinary.loop.currentDaemonState())
        #expect(ordinaryState["serving_selection"] as? [String] == [Fixture.gemmaID, Fixture.glmID, Fixture.superID])
        #expect(ordinaryState["eviction_exclusions"] as? [[String: Any]] == nil
            || (ordinaryState["eviction_exclusions"] as? [[String: Any]])?.isEmpty == true)
    }

    private static func stateJSON(_ state: DaemonState) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
    }
}
