import Foundation
import Testing
@testable import ProviderCore

@Suite("Local analytics")
struct LocalAnalyticsTests {
    @Test("event JSON contains only the reviewed flat schema")
    func eventSchema() throws {
        let event = LocalAnalyticsEvent(
            eventID: "event-1",
            eventAt: Date(timeIntervalSince1970: 1_700_000_000),
            processEpoch: "process-1",
            jobID: "job-1",
            servingMode: "local",
            model: "gemma-test",
            outcome: "success",
            errorClass: nil,
            streaming: true,
            promptTokens: 10,
            completionTokens: 5,
            cachedPromptTokens: 0,
            queueMS: 2,
            ttftMS: 20,
            totalMS: 100,
            decodeTPS: 50)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])

        #expect(object["event_name"] as? String == "inference.completed")
        #expect(object["prompt"] == nil)
        #expect(object["response"] == nil)
        #expect(object["error"] == nil)
        #expect(object["user_id"] == nil)
    }

    @Test("writer atomically publishes a newline-terminated segment")
    func writerPublishesSegment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-analytics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = LocalAnalyticsWriter(rootURL: root, rotationInterval: 3_600)
        writer.record(LocalAnalyticsEvent(
            processEpoch: "process-1",
            jobID: "job-1",
            servingMode: "local",
            model: "gemma-test",
            outcome: "success",
            errorClass: nil,
            streaming: true,
            promptTokens: 10,
            completionTokens: 5,
            cachedPromptTokens: 0,
            queueMS: 2,
            ttftMS: 20,
            totalMS: 100,
            decodeTPS: 50))
        writer.shutdown()

        let ready = root.appendingPathComponent("events/ready")
        let enumerator = try #require(FileManager.default.enumerator(at: ready, includingPropertiesForKeys: nil))
        let segments = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
        #expect(segments.count == 1)
        let data = try Data(contentsOf: #require(segments.first))
        #expect(data.last == 0x0A)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            LocalAnalyticsEvent.self,
            from: data.dropLast())
        #expect(decoded.jobID == "job-1")
    }

    @Test("analytics config is opt-in")
    func configIsOptIn() {
        #expect(ConfigManager.parse("").analytics.enabled == false)
        #expect(ConfigManager.parse("[analytics]\nenabled = true\n").analytics.enabled == true)
    }

    @Test("cold-load capacity errors are classified as rejected capacity")
    func capacityClassification() {
        let error = MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(
            "operator detail must not be persisted")

        #expect(InferenceAnalyticsClassification.outcome(for: error) == "rejected")
        #expect(InferenceAnalyticsClassification.errorClass(for: error) == "capacity")
    }
}
