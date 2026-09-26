import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("apns-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("APNs push history")
struct APNsPushHistoryTests {
    @Test func persistsAcrossStoreInstancesOwnerOnly() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        APNsPushHistoryStore(directory: dir).recordReceipt(at: Date(timeIntervalSince1970: 1_000))
        APNsPushHistoryStore(directory: dir).recordReply(at: Date(timeIntervalSince1970: 1_005))
        APNsPushHistoryStore(directory: dir).recordDeviceToken(present: false, at: Date(timeIntervalSince1970: 1_006))
        let loaded = APNsPushHistoryStore(directory: dir).load()
        #expect(loaded.receivedAt == [1_000])
        #expect(loaded.repliedAt == [1_005])
        #expect(loaded.deviceTokenPresent == false)
        let url = dir.appendingPathComponent(APNsPushHistoryStore.fileName)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!text.contains("token\":\""), "never a device token value")
    }

    @Test func summaryUses24hWindowAndCap() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var history = APNsPushHistory()
        for offset in stride(from: 100_000.0, through: 0, by: -1_000) { history.recordReceipt(at: now.addingTimeInterval(-offset)) }
        #expect(history.receivedAt.count == APNsPushHistory.cap)
        history.recordReply(at: now.addingTimeInterval(-7_200))
        let summary = history.summary(deviceTokenPresent: true, now: now)
        #expect(summary.deviceTokenPresent == true)
        #expect(summary.pushesReceivedLast24h == 50, "all 50 retained receipts fall inside 24 h")
        #expect(summary.lastPushReceivedAgeSeconds == 0)
        #expect(summary.lastReplySentAgeSeconds == 7_200)

        var old = APNsPushHistory(receivedAt: [now.timeIntervalSince1970 - 90_000, now.timeIntervalSince1970 + 60])
        old.recordReply(at: now.addingTimeInterval(120))
        let stale = old.summary(deviceTokenPresent: nil, now: now)
        #expect(stale.pushesReceivedLast24h == 0, "older than 24 h and future timestamps do not count")
        #expect(stale.lastPushReceivedAgeSeconds == nil, "latest is in the future: omit rather than go negative")
        #expect(stale.lastReplySentAgeSeconds == nil)
        #expect(stale.deviceTokenPresent == nil)
    }

    @Test func corruptFileStartsFresh() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = APNsPushHistoryStore(directory: dir)
        try Data("{\"received_at\": \"nope\"".utf8).write(to: store.url)
        #expect(store.load() == APNsPushHistory())
        store.recordReceipt(at: Date(timeIntervalSince1970: 5))
        #expect(store.load().receivedAt == [5])
    }

    @Test func concurrentWritersFromSeparateInstancesKeepEveryTimestamp() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let receipts = APNsPushHistoryStore(directory: dir)
        let replies = APNsPushHistoryStore(directory: dir)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { receipts.recordReceipt(at: Date(timeIntervalSince1970: Double(1_000 + i))) }
                group.addTask { replies.recordReply(at: Date(timeIntervalSince1970: Double(2_000 + i))) }
            }
        }
        let loaded = APNsPushHistoryStore(directory: dir).load()
        #expect(Set(loaded.receivedAt) == Set((0..<20).map { Double(1_000 + $0) }))
        #expect(Set(loaded.repliedAt) == Set((0..<20).map { Double(2_000 + $0) }))
    }

    @Test func wireSummaryIsSnakeCaseAndOutsideClientHash() throws {
        var payload = AppAttestShadowPayload(action: "ready", session: Data(repeating: 0, count: 32).base64EncodedString())
        payload.environment = "production"
        let publicKey = Data(repeating: 3, count: 32).base64EncodedString()
        let before = payload.clientHash(publicKey: publicKey)
        payload.pushHistory = APNsPushHistory(receivedAt: [90], repliedAt: [95])
            .summary(deviceTokenPresent: true, now: Date(timeIntervalSince1970: 100))
        #expect(payload.clientHash(publicKey: publicKey) == before)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        let push = object?["push_history"] as? [String: Any]
        #expect(push?["device_token_present"] as? Bool == true)
        #expect(push?["pushes_received_last_24h"] as? Int == 1)
        #expect(push?["last_push_received_age_seconds"] as? Int == 10)
        #expect(push?["last_reply_sent_age_seconds"] as? Int == 5)
    }
}
