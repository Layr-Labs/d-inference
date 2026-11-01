// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing
@testable import ProviderCore

/// Tool schemas with an allow-all `{}` property on the managed slot. The
/// coordinator sends them normalized with the reserved marker under its
/// authenticated metadata protocol, and this provider's decode marks a legacy
/// coordinator's `{}` itself; both serve. The local endpoint has no such
/// boundary: its unmarked `{}` serves and a client-sent marker is refused.
extension NemotronSuperManagedSlotTests {
    @Test(.timeLimit(.minutes(3)))
    func coordinatorSchemaMetadataServesAndLocalMarkerIsRefused() async throws {
        let fixture = try await Self.fixture(mode: .off)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        func tools(_ x: [String: Any]) -> [String: Any] {
            ["tools": [["type": "function", "function": ["name": "set",
                "parameters": ["type": "object", "properties": ["x": x]]]]]]
        }
        let marked = tools(["type": "string", ToolSchemaNormalization.originalBooleanSchemaKey: true])
        let plain = tools([:])
        let call = ["<tool_call>", "\n<function=set>", "\n<parameter=x>", "\nhi", "\n</parameter>",
                    "\n</function>", "\n</tool_call>"]
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let coordinator = try await Self.send(Self.body(call, script: script, marked), to: loop,
            recorder: recorder, consumer: consumer,
            toolSchemaMetadataProtocol: ToolSchemaNormalization.metadataProtocolVersion)
        #expect(SuperSSE(coordinator.sse).toolCalls.map(\.name) == ["set"], "\(coordinator.terminal)")
        #expect(script.prompt.contains("<name>x</name>"))
        let legacy = try await Self.send(Self.body(call, script: script, plain), to: loop,
                                         recorder: recorder, consumer: consumer)
        #expect(SuperSSE(legacy.sse).toolCalls.map(\.name) == ["set"], "\(legacy.terminal)")
        // Without the protocol the provider refuses the marker before decoding.
        let unauthenticated = try await Self.send(Self.body(["x"], script: script, marked), to: loop,
                                                  recorder: recorder, consumer: consumer)
        #expect(Self.failure(unauthenticated.terminal)?.statusCode == 400, "\(unauthenticated.terminal)")

        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "super-managed"), defaultMaxTokens: 16,
            acquire: { id in try await loop.acquireModelForLocal(id) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { [Self.modelID] }, mtpSlots: { [] },
            managedSuperEngine: { body, request, _ in
                guard request.model == Self.modelID else { return nil }
                return NemotronSuperLocalEndpointEngine(body: body, hasMedia: false, cacheScope: "local",
                    acquire: { try await loop.acquireNemotronSuperForLocal(Self.modelID) })
            })
        // The forged request is refused before generation; the script stays the call.
        let forged = ByteBuffer(bytes: try Self.body(["x"], script: script, marked))
        let unmarked = ByteBuffer(bytes: try Self.body(call, script: script, plain))
        try await app.test(.live) { client in
            let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer super-managed"]
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                                     body: unmarked) { response in
                #expect(response.status == .ok)
                #expect(SuperSSE(String(buffer: response.body)).toolCalls.map(\.name) == ["set"])
            }
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                                     body: forged) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("invalid_request_error"))
            }
        }
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }
}
