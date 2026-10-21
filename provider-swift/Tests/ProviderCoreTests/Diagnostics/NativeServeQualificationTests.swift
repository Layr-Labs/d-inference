import Foundation
@testable import ProviderAppAttest
import Testing
@testable import ProviderCore

@Suite("Native serving qualification guards")
struct NativeServeQualificationTests {
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
        let inputs = try NativeServeQualificationInputs(coordinatorURL: url, path: root.path)
        #expect(inputs.modelID == "local/model")
        #expect(!inputs.workerFaultRequested())
        let marker = root.appendingPathComponent("arm-worker-callback")
        try Data("1".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        #expect(inputs.workerFaultRequested())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        #expect(!inputs.workerFaultRequested())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        try Data("11".utf8).write(to: marker)
        #expect(!inputs.workerFaultRequested())
        try Data("0".utf8).write(to: marker)
        #expect(!inputs.workerFaultRequested())
        try Data("1".utf8).write(to: marker)
        let realMarker = root.appendingPathComponent("real-marker")
        try FileManager.default.moveItem(at: marker, to: realMarker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: realMarker)
        #expect(!inputs.workerFaultRequested())
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
