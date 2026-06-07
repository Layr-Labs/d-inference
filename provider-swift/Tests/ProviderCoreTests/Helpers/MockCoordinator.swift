/// MockCoordinator -- self-contained Hummingbird-based fake coordinator used by
/// the integration test suite. Exposes the same HTTP and WebSocket surface the
/// real coordinator implements, scoped down to whatever the Swift provider's
/// startup, registration, attestation, telemetry, enrollment, model-catalog,
/// release, and update-banner code paths exercise.
///
/// All routes run against a system-assigned port (`127.0.0.1:0`) so multiple
/// integration tests can bring up isolated instances in parallel without
/// stepping on each other. Tests start a mock with `start()`, drive the
/// provider against the returned base URL, push synthetic frames with
/// `pushAttestationChallenge` / `pushInferenceRequest` / `pushCancel`, and
/// drain captured messages via `snapshot()`.
///
/// The mock does not pretend to be cryptographically meaningful: it generates
/// no Secure Enclave material and does not validate signatures. It only
/// exists to round-trip the wire format and the libsodium NaCl box, which are
/// real (the encryption helpers run inside `NodeKeyPair`).

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import Logging
import NIOCore
@testable import ProviderCore

// MARK: - Public types

/// Captured wire messages received from the provider. Cumulative for the
/// lifetime of the mock; tests inspect a snapshot after each interaction.
public struct CapturedMessages: Sendable {
    public var registers: [ProviderMessage.Register] = []
    public var heartbeats: [ProviderMessage.Heartbeat] = []
    public var attestationResponses: [ProviderMessage.AttestationResponse] = []
    public var codeAttestationResponses: [ProviderMessage.CodeAttestationResponse] = []
    public var inferenceAccepted: [ProviderMessage.InferenceAccepted] = []
    public var inferenceChunks: [ProviderMessage.InferenceResponseChunk] = []
    public var inferenceComplete: [ProviderMessage.InferenceComplete] = []
    public var inferenceErrors: [ProviderMessage.InferenceError] = []
    public var loadModelStatuses: [ProviderMessage.LoadModelStatus] = []
    public var prefetchModelStatuses: [ProviderMessage.PrefetchModelStatus] = []
    public var modelsUpdates: [ProviderMessage.ModelsUpdate] = []
    public var telemetryBatches: [TelemetryBatch] = []

    public init() {}
}

/// Events emitted by the mock to let tests synchronize with the WebSocket
/// lifecycle and the messages flowing across it. The stream survives the
/// mock's lifetime; close it via `shutdown()`.
public enum MockEvent: Sendable {
    /// A provider WebSocket connection was upgraded.
    case wsConnected
    /// A wire message was received from the provider.
    case providerMessage(ProviderMessage)
    /// A telemetry batch was POSTed to `/v1/telemetry/events`.
    case telemetryBatchReceived(TelemetryBatch)
    /// The active WebSocket connection ended (cleanly or otherwise).
    case wsClosed
}

/// Override knob for the device-code flow. Defaults to "authorized on first
/// poll" so tests don't have to wait through retry intervals.
public struct MockDeviceCodeFixture: Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: String
    public var expiresIn: Int
    public var interval: Int
    public var token: String
    public var authorizeImmediately: Bool

    public init(
        deviceCode: String = "mock-device-code",
        userCode: String = "MOCK-1234",
        verificationURI: String = "https://example.test/link",
        expiresIn: Int = 300,
        interval: Int = 1,
        token: String = "mock-auth-token",
        authorizeImmediately: Bool = true
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
        self.token = token
        self.authorizeImmediately = authorizeImmediately
    }
}

/// Fixture for `GET /v1/releases/latest`. The shape mirrors what
/// `SelfUpdater` decodes (it accepts `bundle_hash`, `sha256`, or
/// `binary_hash`).
public struct MockReleaseFixture: Sendable {
    public var version: String
    public var platform: String
    public var url: String
    public var bundleHash: String
    public var binaryHash: String?
    public var metallibHash: String?

    public init(
        version: String = "0.99.0",
        platform: String = "macos-arm64",
        url: String = "https://example.test/darkbloom-bundle-macos-arm64.tar.gz",
        bundleHash: String = String(repeating: "a", count: 64),
        binaryHash: String? = nil,
        metallibHash: String? = nil
    ) {
        self.version = version
        self.platform = platform
        self.url = url
        self.bundleHash = bundleHash
        self.binaryHash = binaryHash
        self.metallibHash = metallibHash
    }
}

/// Fixture for `GET /api/version` (the UpdateBanner endpoint).
public struct MockVersionFixture: Sendable {
    public var version: String
    public var changelog: String?

    public init(version: String, changelog: String? = nil) {
        self.version = version
        self.changelog = changelog
    }
}

// MARK: - MockCoordinator

public final class MockCoordinator: @unchecked Sendable {

    // MARK: Fixtures

    /// Default catalog used by `GET /v1/models/catalog` unless overridden.
    public static let defaultCatalog: [CatalogModel] = [
        CatalogModel(
            id: "mlx-community/Qwen3-0.6B-8bit",
            s3Name: "Qwen3-0.6B-8bit",
            displayName: "Qwen3 0.6B 8bit",
            modelType: "text",
            sizeGb: 0.7,
            architecture: "0.6B dense",
            description: "Tiny test model",
            minRamGb: 4,
            active: true,
            weightHash: String(repeating: "d", count: 64)
        )
    ]

    /// Default `.mobileconfig` payload returned by `/v1/enroll`. The bytes are
    /// just an opaque blob -- tests assert exact equality, the macOS profile
    /// installer is never invoked.
    public static let defaultMobileConfig: Data = Data(
        "MOCK_MOBILECONFIG_BYTES_<darkbloom-test-fixture>".utf8
    )

    public let catalog: [CatalogModel]
    public let release: MockReleaseFixture
    public let version: MockVersionFixture
    public let mobileConfig: Data
    public let deviceCode: MockDeviceCodeFixture

    // MARK: State

    private let lock = NSLock()
    private var captured = CapturedMessages()
    private var activeOutbound: WebSocketOutboundWriter?
    private var bound: BoundServer?

    private let (eventStream, eventContinuation): (
        AsyncStream<MockEvent>, AsyncStream<MockEvent>.Continuation
    ) = {
        let (s, c) = AsyncStream<MockEvent>.makeStream(bufferingPolicy: .unbounded)
        return (s, c)
    }()

    private struct BoundServer {
        let baseURL: URL
        let serverTask: Task<Void, Never>
    }

    // MARK: Init

    public init(
        catalog: [CatalogModel] = MockCoordinator.defaultCatalog,
        release: MockReleaseFixture = MockReleaseFixture(),
        version: MockVersionFixture = MockVersionFixture(version: "0.5.0"),
        mobileConfig: Data = MockCoordinator.defaultMobileConfig,
        deviceCode: MockDeviceCodeFixture = MockDeviceCodeFixture()
    ) {
        self.catalog = catalog
        self.release = release
        self.version = version
        self.mobileConfig = mobileConfig
        self.deviceCode = deviceCode
    }

    // MARK: Public API

    /// AsyncStream of lifecycle and message events. Iterate with caution: the
    /// stream only finishes when `shutdown()` is called.
    public var events: AsyncStream<MockEvent> { eventStream }

    /// Return a snapshot of all messages captured so far. Each call clones the
    /// underlying state, so the returned value is safe to inspect without
    /// holding any locks.
    public func snapshot() -> CapturedMessages {
        lock.withLock { captured }
    }

    /// Bring the server up on a system-assigned port and return the bound
    /// base URL. The WebSocket route is at `${baseURL}/ws/provider` (with
    /// `ws://` scheme); HTTP routes use the returned URL directly.
    public func start() async throws -> URL {
        // Hummingbird logs at .error during graceful shutdown ("Already
        // closed", child-channel cancellation) which pollutes the test
        // output without indicating a real problem. Crank the level so the
        // mock is silent in normal runs; bump back down with an env var if
        // you're debugging the harness itself.
        var logger = Logger(label: "MockCoordinator")
        if let envLevel = ProcessInfo.processInfo.environment["MOCK_COORDINATOR_LOG_LEVEL"],
           let level = Logger.Level(rawValue: envLevel)
        {
            logger.logLevel = level
        } else {
            logger.logLevel = .critical
        }
        let router = makeRouter()

        // Hummingbird picks an ephemeral port when port == 0; we discover the
        // actual port via onServerRunning. Funneled through a one-shot
        // continuation so start() can resolve only once the listening socket
        // is up.
        let portBox = PortBox()

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(
                address: .hostname("127.0.0.1", port: 0),
                serverName: "MockCoordinator"
            ),
            onServerRunning: { @Sendable channel in
                let port = channel.localAddress?.port ?? 0
                portBox.complete(port)
            },
            logger: logger
        )

        let serverTask = Task<Void, Never> {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                // ServiceGroup swallows cancellation; anything else is a
                // bug in the test harness, not the production code we care
                // about. Signal it via the event stream so the test can
                // notice if it's looking.
                logger.warning("MockCoordinator server crashed: \(error)")
            }
        }

        let port = await portBox.value
        guard port > 0 else {
            serverTask.cancel()
            throw MockCoordinatorError.failedToBind
        }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        lock.withLock {
            self.bound = BoundServer(baseURL: baseURL, serverTask: serverTask)
        }
        return baseURL
    }

    /// Shut down the mock, closing any active WebSocket and stopping the
    /// HTTP server. Safe to call multiple times.
    public func shutdown() async {
        let snapshot: BoundServer? = lock.withLock {
            let outbound = self.activeOutbound
            self.activeOutbound = nil
            let bound = self.bound
            self.bound = nil
            // Close the WS politely; ignore failures.
            if let outbound {
                Task { try? await outbound.close(.goingAway, reason: nil) }
            }
            return bound
        }
        snapshot?.serverTask.cancel()
        _ = await snapshot?.serverTask.value
        eventContinuation.finish()
    }

    /// Wait until `predicate` becomes true on a fresh snapshot, polling at
    /// roughly 25ms intervals. Returns the matching snapshot or nil after the
    /// deadline.
    public func waitForSnapshot(
        timeout: Duration = .seconds(5),
        where predicate: @Sendable (CapturedMessages) -> Bool
    ) async throws -> CapturedMessages? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let s = snapshot()
            if predicate(s) { return s }
            try await Task.sleep(for: .milliseconds(25))
        }
        let final = snapshot()
        return predicate(final) ? final : nil
    }

    /// Wait for the first register message and return it.
    public func awaitFirstRegister(
        timeout: Duration = .seconds(5)
    ) async throws -> ProviderMessage.Register? {
        let s = try await waitForSnapshot(timeout: timeout) { !$0.registers.isEmpty }
        return s?.registers.first
    }

    // MARK: Push helpers

    public func pushAttestationChallenge(
        nonce: String,
        timestamp: String
    ) async throws {
        let msg = CoordinatorMessage.attestationChallenge(.init(nonce: nonce, timestamp: timestamp))
        try await sendCoordinatorMessage(msg)
    }

    /// Encrypt `chatRequestJSON` to `providerPublicKeyBase64` using a fresh
    /// ephemeral keypair, then push a synthetic `inference_request` over the
    /// active WebSocket.
    public func pushInferenceRequest(
        requestId: String,
        providerPublicKeyBase64: String,
        chatRequestJSON: Data
    ) async throws {
        guard let providerPubKeyData = Data(base64Encoded: providerPublicKeyBase64),
              providerPubKeyData.count == 32
        else {
            throw MockCoordinatorError.invalidProviderPublicKey
        }
        let consumerKeys = NodeKeyPair.generate()
        let payload = try consumerKeys.encryptPayload(
            recipientPublicKey: providerPubKeyData,
            plaintext: chatRequestJSON
        )
        let msg = CoordinatorMessage.inferenceRequest(.init(
            requestId: requestId,
            body: .null,
            encryptedBody: payload
        ))
        try await sendCoordinatorMessage(msg)
    }

    public func pushCancel(requestId: String) async throws {
        let msg = CoordinatorMessage.cancel(.init(requestId: requestId))
        try await sendCoordinatorMessage(msg)
    }

    public func pushLoadModel(modelId: String) async throws {
        let msg = CoordinatorMessage.loadModel(.init(modelId: modelId))
        try await sendCoordinatorMessage(msg)
    }

    /// Force-close the active provider WebSocket so the provider's reconnect
    /// loop kicks in.
    public func dropActiveWebSocket() async {
        let outbound: WebSocketOutboundWriter? = lock.withLock {
            let o = self.activeOutbound
            self.activeOutbound = nil
            return o
        }
        if let outbound {
            try? await outbound.close(.goingAway, reason: "mock dropping")
        }
    }

    // MARK: Internals

    private func sendCoordinatorMessage(_ msg: CoordinatorMessage) async throws {
        let outbound: WebSocketOutboundWriter? = lock.withLock { activeOutbound }
        guard let outbound else { throw MockCoordinatorError.noActiveWebSocket }
        let json = try ProviderProtocolCodec.encodeCoordinatorMessageString(msg)
        try await outbound.write(.text(json))
    }

    // MARK: Router

    private func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)

        // ----- WebSocket: /ws/provider -----
        router.ws("/ws/provider") { [weak self] inbound, outbound, _ in
            guard let self else { return }
            self.lock.withLock { self.activeOutbound = outbound }
            self.eventContinuation.yield(.wsConnected)
            defer {
                self.lock.withLock {
                    if self.activeOutbound != nil {
                        self.activeOutbound = nil
                    }
                }
                self.eventContinuation.yield(.wsClosed)
            }

            do {
                var iterator = inbound.makeAsyncIterator()
                while let message = try await iterator.nextMessage(maxSize: 1_000_000) {
                    switch message {
                    case .text(let text):
                        self.handleProviderMessage(text)
                    case .binary(let buffer):
                        if let text = buffer.getString(at: buffer.readerIndex,
                                                      length: buffer.readableBytes) {
                            self.handleProviderMessage(text)
                        }
                    }
                }
            } catch {
                // Connection-level errors (closed, protocol error) end the
                // handler. The defer above tags it as closed.
            }
        }

        // ----- HTTP: /v1/models/catalog -----
        router.get("/v1/models/catalog") { [weak self] _, _ -> Response in
            guard let self else {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "mock dead"], status: .internalServerError
                )
            }
            return MockCoordinator.makeJSONResponse(body: ["models": self.catalog])
        }

        // ----- HTTP: /v1/releases/latest -----
        router.get("/v1/releases/latest") { [weak self] _, _ -> Response in
            guard let self else {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "mock dead"], status: .internalServerError
                )
            }
            let body = ReleaseLatestPayload(
                version: self.release.version,
                platform: self.release.platform,
                url: self.release.url,
                bundle_hash: self.release.bundleHash,
                binary_hash: self.release.binaryHash,
                metallib_hash: self.release.metallibHash
            )
            return MockCoordinator.makeJSONResponse(body: body)
        }

        // ----- HTTP: /api/version (UpdateBanner) -----
        router.get("/api/version") { [weak self] _, _ -> Response in
            guard let self else {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "mock dead"], status: .internalServerError
                )
            }
            let body = APIVersionPayload(
                version: self.version.version,
                changelog: self.version.changelog
            )
            return MockCoordinator.makeJSONResponse(body: body)
        }

        // ----- HTTP: /v1/enroll -----
        router.post("/v1/enroll") { [weak self] _, _ -> Response in
            guard let self else {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "mock dead"], status: .internalServerError
                )
            }
            return Response(
                status: .ok,
                headers: [.contentType: "application/x-apple-aspen-config"],
                body: .init(byteBuffer: ByteBuffer(bytes: self.mobileConfig))
            )
        }

        // ----- HTTP: /v1/device/code -----
        router.post("/v1/device/code") { [weak self] _, _ -> Response in
            guard let self else {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "mock dead"], status: .internalServerError
                )
            }
            let body = DeviceCodePayload(
                device_code: self.deviceCode.deviceCode,
                user_code: self.deviceCode.userCode,
                verification_uri: self.deviceCode.verificationURI,
                expires_in: self.deviceCode.expiresIn,
                interval: self.deviceCode.interval
            )
            return MockCoordinator.makeJSONResponse(body: body)
        }

        // ----- HTTP: /v1/device/token -----
        router.post("/v1/device/token") { [weak self] _, _ -> Response in
            guard let self else {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "mock dead"], status: .internalServerError
                )
            }
            if self.deviceCode.authorizeImmediately {
                let body = DeviceTokenAuthorized(
                    status: "authorized",
                    token: self.deviceCode.token
                )
                return MockCoordinator.makeJSONResponse(body: body)
            } else {
                let body = DeviceTokenPending(status: "authorization_pending")
                return MockCoordinator.makeJSONResponse(body: body)
            }
        }

        // ----- HTTP: /v1/telemetry/events -----
        router.post("/v1/telemetry/events") { [weak self] request, _ -> Response in
            guard let self else {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "mock dead"], status: .internalServerError
                )
            }
            let buffer: ByteBuffer
            do {
                buffer = try await request.body.collect(upTo: 5_000_000)
            } catch {
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "body collection failed: \(error)"],
                    status: .badRequest
                )
            }
            let body = Data(buffer: buffer)
            do {
                let batch = try JSONDecoder().decode(TelemetryBatch.self, from: body)
                self.lock.withLock { self.captured.telemetryBatches.append(batch) }
                self.eventContinuation.yield(.telemetryBatchReceived(batch))
            } catch {
                // Treat malformed payloads as a 400 so tests can detect drift
                // in the telemetry wire format.
                return MockCoordinator.makeJSONResponse(
                    body: ["error": "decode failed: \(error)"],
                    status: .badRequest
                )
            }
            return MockCoordinator.makeJSONResponse(body: ["accepted": true])
        }

        return router
    }

    private func handleProviderMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let parsed = try? ProviderProtocolCodec.decodeProviderMessage(from: data) else {
            return
        }

        lock.withLock {
            switch parsed {
            case .register(let r):           captured.registers.append(r)
            case .heartbeat(let h):          captured.heartbeats.append(h)
            case .attestationResponse(let a): captured.attestationResponses.append(a)
            case .codeAttestationResponse(let c): captured.codeAttestationResponses.append(c)
            case .inferenceAccepted(let a):   captured.inferenceAccepted.append(a)
            case .inferenceResponseChunk(let c): captured.inferenceChunks.append(c)
            case .inferenceComplete(let c):   captured.inferenceComplete.append(c)
            case .inferenceError(let e):      captured.inferenceErrors.append(e)
            case .loadModelStatus(let s):    captured.loadModelStatuses.append(s)
            case .prefetchModelStatus(let s): captured.prefetchModelStatuses.append(s)
            case .modelsUpdate(let u):       captured.modelsUpdates.append(u)
            }
        }
        eventContinuation.yield(.providerMessage(parsed))
    }

    // MARK: Response helpers

    private static func makeJSONResponse<T: Encodable>(
        body: T,
        status: HTTPResponse.Status = .ok
    ) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            data = Data("{\"error\":\"encode failed\"}".utf8)
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}

// MARK: - Errors

public enum MockCoordinatorError: Error, CustomStringConvertible, Sendable {
    case failedToBind
    case noActiveWebSocket
    case invalidProviderPublicKey

    public var description: String {
        switch self {
        case .failedToBind:               "Mock coordinator failed to bind a port"
        case .noActiveWebSocket:          "No active provider WebSocket on the mock"
        case .invalidProviderPublicKey:   "Provider public key was not a 32-byte X25519 key"
        }
    }
}

// MARK: - One-shot port box

/// One-shot async box for the bound port. `complete(_:)` is fired from
/// Hummingbird's `onServerRunning` callback; `value` is awaited from
/// `start()`.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var continuation: CheckedContinuation<Int, Never>?

    var value: Int {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                lock.withLock {
                    if let p = port {
                        cont.resume(returning: p)
                    } else {
                        continuation = cont
                    }
                }
            }
        }
    }

    func complete(_ port: Int) {
        let cont: CheckedContinuation<Int, Never>? = lock.withLock {
            if self.port != nil { return nil }
            self.port = port
            let cont = continuation
            continuation = nil
            return cont
        }
        cont?.resume(returning: port)
    }
}

// MARK: - Wire payload structs

private struct ReleaseLatestPayload: Encodable {
    let version: String
    let platform: String
    let url: String
    let bundle_hash: String
    let binary_hash: String?
    let metallib_hash: String?
}

private struct APIVersionPayload: Encodable {
    let version: String
    let changelog: String?
}

private struct DeviceCodePayload: Encodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int
}

private struct DeviceTokenAuthorized: Encodable {
    let status: String
    let token: String
}

private struct DeviceTokenPending: Encodable {
    let status: String
}

// MARK: - URL helpers

extension URL {
    /// Convert a `http(s)://host:port` base URL into the `ws(s)://...` URL
    /// where the mock coordinator's `/ws/provider` route lives.
    public func mockProviderWebSocketURL() -> String {
        let scheme = (self.scheme == "https") ? "wss" : "ws"
        let host = self.host ?? "127.0.0.1"
        let port = self.port ?? 80
        return "\(scheme)://\(host):\(port)/ws/provider"
    }
}

// MARK: - NSLock convenience

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}
