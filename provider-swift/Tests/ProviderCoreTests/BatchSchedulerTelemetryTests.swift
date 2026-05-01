import Testing
@testable import ProviderCore

@Suite("BatchScheduler telemetry + capacity helpers")
struct BatchSchedulerTelemetryTests {

    @Test("capacity counters report pending requests and active tokens")
    func capacityCountersReflectRequestProgress() {
        let counters = SchedulerCapacityCounters.from([
            InferenceRequestProgress(promptTokens: 12, completionTokens: 0, firstTokenReceived: false),
            InferenceRequestProgress(promptTokens: 9, completionTokens: 3, firstTokenReceived: true),
            InferenceRequestProgress(promptTokens: 4, completionTokens: 1, firstTokenReceived: true),
        ])

        #expect(counters.activeRequests == 3)
        #expect(counters.pendingRequests == 1)
        #expect(counters.activeTokens == 29)
    }

    @Test("lifecycle telemetry event includes request correlation and timing fields")
    func lifecycleTelemetryEventConstruction() {
        let snapshot = InferenceLifecycleTelemetrySnapshot(
            requestId: "req-123",
            model: "mlx-community/test-model",
            promptTokens: 17,
            completionTokens: 5,
            queueMilliseconds: 2.5,
            admitMilliseconds: 3.25,
            ttftMilliseconds: 42.75,
            totalMilliseconds: 123.5,
            activeCount: 4
        )

        let event = InferenceLifecycleTelemetry.event(.inferenceComplete, snapshot: snapshot)

        #expect(event.requestId == "req-123")
        #expect(event.message == "inference_complete")
        #expect(event.severity == .info)
        #expect(event.kind == .custom)
        #expect(event.fields?["operation"]?.description == "inference_complete")
        #expect(event.fields?["model"]?.description == "mlx-community/test-model")
        #expect(event.fields?["prompt_tokens"]?.description == "17")
        #expect(event.fields?["completion_tokens"]?.description == "5")
        #expect(event.fields?["queue_ms"]?.description == "2.5")
        #expect(event.fields?["admit_ms"]?.description == "3.25")
        #expect(event.fields?["ttft_ms"]?.description == "42.75")
        #expect(event.fields?["total_ms"]?.description == "123.5")
        #expect(event.fields?["active_count"]?.description == "4")
    }

    @Test("telemetry field filter preserves lifecycle metrics")
    func telemetryFieldFilterAllowsLifecycleMetrics() {
        let filtered = TelemetryFieldFilter.filter([
            "operation": .string("first_token"),
            "prompt_tokens": .int(10),
            "completion_tokens": .int(1),
            "queue_ms": .double(1.0),
            "admit_ms": .double(2.0),
            "ttft_ms": .double(3.0),
            "total_ms": .double(4.0),
            "active_count": .int(2),
            "not_allowed": .string("drop"),
        ])

        #expect(filtered?["operation"]?.description == "first_token")
        #expect(filtered?["prompt_tokens"]?.description == "10")
        #expect(filtered?["completion_tokens"]?.description == "1")
        #expect(filtered?["queue_ms"]?.description == "1.0")
        #expect(filtered?["admit_ms"]?.description == "2.0")
        #expect(filtered?["ttft_ms"]?.description == "3.0")
        #expect(filtered?["total_ms"]?.description == "4.0")
        #expect(filtered?["active_count"]?.description == "2")
        #expect(filtered?["not_allowed"] == nil)
    }
}
