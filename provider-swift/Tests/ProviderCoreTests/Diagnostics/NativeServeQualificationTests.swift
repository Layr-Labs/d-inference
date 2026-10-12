import Foundation
@testable import ProviderAppAttest
import Testing
@testable import ProviderCore

@Suite("Native serving qualification guards")
struct NativeServeQualificationTests {
    @Test func failedObserverDoesNotWaitForUncancellableServe() async throws {
        enum Failure: Error { case failedDrain }
        let held = QualificationHeldServe()
        let task = Task {
            try await NativeServeRunLifetime.run(serve: { await held.wait() }, observe: {
                while !(await held.entered) { await Task.yield() }
                throw Failure.failedDrain
            })
        }
        do { try await task.value; Issue.record("failed drain became success") }
        catch Failure.failedDrain {}
        // The diagnostic CLI exits on this failure; the unit test instead
        // explicitly releases its synthetic held operation and joins it.
        await held.release()
    }

    @Test func literalLoopbackOnly() throws {
        #expect(try NativeServeQualificationInputs.validateURL("ws://127.0.0.1:12345/ws/provider") == "ws://127.0.0.1:12345/ws/provider")
        for value in ["wss://127.0.0.1:12345/ws/provider", "ws://localhost:12345/ws/provider",
                      "ws://127.0.0.2:12345/ws/provider", "ws://127.0.0.1:80/ws/provider",
                      "ws://127.0.0.1:12345/ws/provider?x=1", "ws://u@127.0.0.1:12345/ws/provider",
                      "ws://127.0.0.1:12345/ws/provider#x", "ws://127.0.0.1:012345/ws/provider"] {
            #expect(throws: (any Error).self) { try NativeServeQualificationInputs.validateURL(value) }
        }
    }

    @Test func privateInputsRejectSymlinksAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let token = root.appendingPathComponent("auth-token")
        try Data(String(repeating: "a", count: 64).utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let model = root.appendingPathComponent("model-id")
        try Data("local/model".utf8).write(to: model)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: model.path)
        let url = "ws://127.0.0.1:12345/ws/provider"
        #expect(try NativeServeQualificationInputs(coordinatorURL: url, path: root.path).modelID == "local/model")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: token.path)
        #expect(throws: (any Error).self) { try NativeServeQualificationInputs(coordinatorURL: url, path: root.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        try FileManager.default.moveItem(at: token, to: root.appendingPathComponent("real-token"))
        try FileManager.default.createSymbolicLink(at: token, withDestinationURL: root.appendingPathComponent("real-token"))
        #expect(throws: (any Error).self) { try NativeServeQualificationInputs(coordinatorURL: url, path: root.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try NativeServeQualificationInputs(coordinatorURL: url, path: root.path) }
    }

    @Test func inMemoryKeyBudgetSurvivesWithinRunOnly() throws {
        let storage = NativeServeKeyStorage()
        let record = ShadowKeyRecord(keyID: "opaque-apple-id", attested: false, createdAt: Date())
        try storage.save(record, scope: "budget")
        try storage.save(record, scope: "account")
        #expect(try storage.load(scope: "budget")?.keyID == record.keyID)
        #expect(try storage.load(scope: "account")?.keyID == record.keyID)
        #expect(try NativeServeKeyStorage().load(scope: "budget") == nil)
        for index in 0..<6 { try storage.save(record, scope: "scope-\(index)") }
        #expect(throws: (any Error).self) { try storage.save(record, scope: "overflow") }
    }
}

private actor QualificationHeldServe {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { entered = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
