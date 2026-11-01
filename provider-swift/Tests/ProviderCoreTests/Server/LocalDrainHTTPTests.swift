import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

@Suite("Local HTTP drain refusals")
struct LocalDrainHTTPTests {
    @Test func drainedPostReturnsCapacityEnvelopeWithoutLoading() async throws {
        let server = StandaloneServer(config: .init(port: 0, host: "127.0.0.1",
            authToken: "synthetic-drain-test-token"))
        let identity = try #require(ProcessIdentity.current())
        let drained = await server.drainForLifecycle(
            ProviderDrainRequest(target: identity, timeoutSeconds: 0))
        #expect(drained.outcome == .drained)
        let app = server.makeApplication()
        try await app.test(.live) { client in
            for path in ["/v1/chat/completions", "/v1/responses", "/v1/completions"] {
                // Admission closes before request-body parsing or model acquisition.
                try await client.execute(uri: path, method: .post,
                    headers: [.contentType: "application/json",
                              .authorization: "Bearer synthetic-drain-test-token"],
                    body: ByteBuffer(string: "{}")) { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(response.headers[.contentType] == "application/json")
                    #expect(response.headers[.accessControlAllowOrigin] == "*")
                    let error = try JSONDecoder().decode(OpenAIErrorResponse.self,
                        from: Data(String(buffer: response.body).utf8))
                    #expect(error.error.type == "invalid_request_error")
                    #expect(error.error.message == InferenceFailureCode.capacity.message)
                }
            }
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/v1/chat/completions", method: .options) { response in
                #expect(response.status == .noContent)
            }
        }
        #expect(server.responseTracker.activeCount == 0)
        #expect(await server.slots.isEmpty)
    }
}
