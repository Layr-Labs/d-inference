import Foundation
import Testing
@testable import ProviderCore

@Test func desktopSessionUsageAccumulatesConcurrentPromptsWithoutChangingWireStats() async throws {
    let stats = AtomicProviderStats()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<100 {
            group.addTask {
                stats.addPromptTokensProcessed(120)
                stats.addTokensGenerated(30)
            }
        }
    }
    #expect(stats.promptTokensProcessed == 12_000)
    #expect(stats.snapshot().tokensGenerated == 3_000)
    let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats.snapshot())) as! [String: Any]
    #expect(wire["promptTokensProcessed"] == nil)
}

@Test func desktopSessionUsageDecodesOldDaemonAsUnknownInput() throws {
    let old = Data(#"{"requestsServed":12,"tokensGenerated":5641,"usageGaps":0}"#.utf8)
    let stats = try JSONDecoder().decode(DaemonState.Stats.self, from: old)
    #expect(stats.tokensGenerated == 5641)
    #expect(stats.promptTokensProcessed == nil)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats)) as! [String: Any]
    #expect(encoded["promptTokensProcessed"] == nil)
}

@Test func desktopSessionUsageRoundTripsExplicitZeroAndLargeCounts() throws {
    for input: UInt64 in [0, 9_007_199_254_740_993] {
        let stats = DaemonState.Stats(requestsServed: 1, tokensGenerated: 30, promptTokensProcessed: input)
        let decoded = try JSONDecoder().decode(DaemonState.Stats.self, from: JSONEncoder().encode(stats))
        #expect(decoded.promptTokensProcessed == input)
    }
}

@Test func desktopSessionUsageJournalDeduplicatesAndSurvivesReopen() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    let history = ProviderUsageHistory(url: url)
    let record = ProviderUsageRecord(id: "one", sessionStartedAt: 100, completedAt: 110, model: "test",
      inputTokens: 120, outputTokens: 30, cachedInputTokens: 80, reasoningTokens: 20, exact: true)
    #expect(try history.record(record))
    #expect(try !history.record(record))
    let restored = ProviderUsageHistory(url: url)
    #expect(try !restored.record(record))
    #expect(ProviderUsageHistory.read(url: url) == [record])
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let otherSession = ProviderUsageRecord(id: "one", sessionStartedAt: 200, model: "test",
      inputTokens: 10, outputTokens: 5, cachedInputTokens: 999, reasoningTokens: 999, exact: false)
    #expect(otherSession.cachedInputTokens == 10)
    #expect(otherSession.reasoningTokens == 5)
    #expect(try restored.record(otherSession))
    #expect(ProviderUsageHistory.read(url: url).count == 2)
}

@Test func desktopSessionUsageSubsetsDoNotIncreaseTheTotal() {
    let stats = AtomicProviderStats()
    stats.addPromptTokensProcessed(120); stats.addTokensGenerated(30)
    stats.addCachedInputTokens(80); stats.addReasoningTokens(20)
    #expect(stats.promptTokensProcessed + stats.tokensGenerated == 150)
    #expect(stats.cachedInputTokens == 80)
    #expect(stats.reasoningTokens == 20)
}

private func usageRecord(_ id: String, session: Double = 100) -> ProviderUsageRecord {
    ProviderUsageRecord(id: id, sessionStartedAt: session, completedAt: 110, model: "test",
      inputTokens: 120, outputTokens: 30, cachedInputTokens: nil, reasoningTokens: nil, exact: true)
}

@Test func desktopSessionUsageJournalCoalescesEnqueuedRecordsUntilFlush() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    let history = ProviderUsageHistory(url: url, flushInterval: 3600)
    let records = (0..<3).map { usageRecord("r\($0)") }
    for record in records { history.enqueue(record) }
    history.enqueue(records[0])
    // A per-record writer replaces the file within milliseconds of enqueue.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    history.flush()
    #expect(ProviderUsageHistory.read(url: url) == records)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func desktopSessionUsageJournalSavesEnqueuedRecordsAfterTheInterval() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    let history = ProviderUsageHistory(url: url, flushInterval: 0.05)
    history.enqueue(usageRecord("one"))
    history.enqueue(usageRecord("two"))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ProviderUsageHistory.read(url: url).count < 2 && ContinuousClock.now < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(ProviderUsageHistory.read(url: url).map(\.id) == ["one", "two"])
}

@Test func desktopSessionUsageJournalKeepsTheNewestRecordsAtCapacity() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.json")
    let history = ProviderUsageHistory(url: url, flushInterval: 3600)
    for index in 0..<4100 { history.enqueue(usageRecord("r\(index)")) }
    history.flush()
    let saved = ProviderUsageHistory.read(url: url)
    #expect(saved.count == 4096)
    #expect(saved.first?.id == "r4")
    #expect(saved.last?.id == "r4099")
}
