import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("apns-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class SentMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func append(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var last: OutboundMessage? { lock.withLock { messages.last } }
    var count: Int { lock.withLock { messages.count } }
}

@Suite("APNs push history")
struct APNsPushHistoryTests {
    // Resume challenges arrive over the WebSocket and reuse the code-challenge
    // handler; only the APNs push handler may record a push reply.
    @Test func resumeChallengeReplyIsNotRecordedAsAPushReply() async throws {
        guard let signer = try SecureEnclaveIdentity.createEphemeral() else { return }
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
            chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(config: ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [], config: ProviderConfig(provider: ProviderSettings(name: "push-history-test"))),
            purgeLegacyFiles: false, attestationSigner: signer)
        await loop.setDaemonStateFileForTesting(dir.appendingPathComponent("state.json"))
        let recipient = try #require(Data(base64Encoded: await loop.keyPair.publicKeyBase64))
        let challenge = try NodeKeyPair.generate().encryptPayload(recipientPublicKey: recipient, plaintext: Data("nonce".utf8))
        let sent = SentMessages()
        #expect(await loop.handleCodeChallenge(challenge, send: SendHandle { sent.append($0) }))
        #expect(sent.count == 1)
        let history = APNsPushHistoryStore(directory: dir)
        #expect(history.load().repliedAt.isEmpty)
        #expect(sent.last?.onWritten == nil, "resume replies never record APNs history")
        #expect(await loop.handleCodeChallenge(challenge, send: SendHandle { sent.append($0) },
                                              onWritten: { history.recordReply() }))
        #expect(history.load().repliedAt.isEmpty, "enqueueing or dropping a frame is not a successful write")
        let completion = try #require(sent.last?.onWritten)
        completion() // successful NWConnection contentProcessed callback
        #expect(history.load().repliedAt.count == 1)
    }

    @Test func tokenCallbacksRemainTrackedAfterStartupWaiterExpires() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = APNsPushHistoryStore(directory: dir)
        let bridge = APNsBridge()
        bridge.trackDeviceToken(in: history)
        #expect(history.load().deviceTokenPresent == false)
        #expect(await bridge.awaitDeviceToken(timeoutSeconds: 0) == nil)
        bridge.setDeviceToken("late-token")
        #expect(history.load().deviceTokenPresent == true)
        // Installation after an early token also sees the live value.
        bridge.trackDeviceToken(in: history)
        #expect(history.load().deviceTokenPresent == true)
        #expect(!String(decoding: try Data(contentsOf: history.url), as: UTF8.self).contains("late-token"))
    }

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
