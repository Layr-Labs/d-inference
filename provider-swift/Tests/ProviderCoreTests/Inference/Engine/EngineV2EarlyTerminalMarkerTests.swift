import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Deadline-admits one request, answers it at once and returns a retirement
/// the test releases: the shape of an early terminal, whose rows stay owned
/// until the donor's complete-checkpoint publication ends.
private final class RetiringLaterEngine: CBv2Engine, @unchecked Sendable {
    let retirement = PrefillRetirementGate()
    private let lock = NSLock()
    private var submitted: [CBv2Request] = []

    var requests: [CBv2Request] { lock.withLock { submitted } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        Issue.record("expected atomic deadline admission")
        return AsyncStream { $0.finish() }
    }

    func submit(
        _ request: CBv2Request,
        firstTokenDeadline: CBv2FirstTokenDeadlineAdmission
    ) async throws -> CBv2FirstTokenDeadlineResult {
        lock.withLock { submitted.append(request) }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 2, completionTokens: 0)))
        continuation.finish()
        return .admitted(
            stream: stream,
            projectedWork: .bounded(
                work: .init(prefillTokens: request.promptTokens.count,
                    decodeTokens: 0, scheduledSteps: 1, mixedSteps: 0),
                serviceDuration: .milliseconds(1)),
            admittedAt: .now,
            retirement: retirement.retirement)
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

private final class MarkerTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEvent] = []

    func record(_ event: TelemetryEvent) { lock.withLock { events.append(event) } }

    var markers: [TelemetryEvent] {
        lock.withLock {
            events.filter { $0.fields?["operation"]?.value as? String == "ssd_terminal_before_publication" }
        }
    }
}

/// With the early-terminal opt-in, a request whose retirement (its
/// complete-checkpoint publication, then the rows' release) comes after the
/// client's terminal is marked once it retires, with how long that took: the
/// per-request evidence a measurement of the opt-in needs.
@Suite("Early terminal marker")
struct EngineV2EarlyTerminalMarkerTests {
    @Test(arguments: [
        (optIn: true, seeded: false, held: true),
        (optIn: true, seeded: false, held: false),
        (optIn: true, seeded: true, held: true),
        (optIn: false, seeded: false, held: true),
    ])
    func aRequestRetiredAfterItsTerminalIsMarkedWithTheTimeItHeld(
        optIn: Bool, seeded: Bool, held: Bool
    ) async throws {
        let engine = RetiringLaterEngine()
        let telemetry = MarkerTelemetry()
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: "early-terminal",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, kvBytesPerToken: 4_000, kvBudget: budget,
            terminalBeforeCheckpointPublication: optIn, emitTelemetry: telemetry.record)
        await bridge.updatePrefillTpsEwma(2_000, isolated: true)
        defer { engine.retirement.release() }
        if !held { engine.retirement.release() }

        let stream = try await bridge.submitTokenized(promptTokens: [1, 2],
            request: .init(model: "early-terminal", messages: [], max_tokens: 10, seed: seeded ? 7 : nil),
            requestId: "early", firstContentDeadline: FirstContentDeadline(relativeBudgetMilliseconds: 60_000))
        var answered = false
        for await event in stream {
            if case .info = event { answered = true }
        }
        #expect(answered)
        #expect(engine.requests.map(\.terminalPrecedesCheckpointPublication) == [optIn && !seeded])
        // The answer is out; the publication still holds the rows.
        #expect(telemetry.markers.isEmpty)

        try await Task.sleep(for: .milliseconds(50))
        engine.retirement.release()
        let limit = ContinuousClock.now + .seconds(5)
        while await bridge._testLivePumpCount() > 0, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await bridge._testLivePumpCount() == 0)
        let markers = telemetry.markers
        guard optIn, !seeded, held else {
            #expect(markers.isEmpty)
            return
        }
        let marker = try #require(markers.first)
        #expect(markers.count == 1)
        #expect(marker.requestId == "early")
        #expect(marker.fields?["model"]?.value as? String == "early-terminal")
        let heldMs = try #require(marker.fields?["retired_after_terminal_ms"]?.value as? Int)
        #expect(heldMs >= 50)
    }
}
