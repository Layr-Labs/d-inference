/// `darkbloom update` on pair-2's MacBook (DevNet, 2026-11-07) failed twice with "download failed: update check failed:
/// The request timed out", a minute each, while the coordinator answered `curl` in 0.3 s: the release check sent one
/// request, waited the shared session's 60 s for an answer and never asked again. The coordinator here is answered
/// in-process, one scripted step per request (`ScriptedReleaseProtocol`), or is a loopback peer that takes the
/// connection and never answers (`SilentPeer`). Install roots are temporary; nothing is downloaded or installed.

import Foundation
import Testing
@testable import ProviderCore

@Suite("Release check")
struct SelfUpdaterReleaseCheckTests {

    @Test("a check that times out asks again and finds the release")
    func timeoutIsAskedAgain() async throws {
        let check = try ReleaseCheckFixture([.fail(.timedOut), .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .updateAvailable(_, let latest) = result else {
            Issue.record("expected the release from the second try, got \(result)")
            return
        }
        #expect(latest.version == "99.0.0")
        #expect(check.requests.count == 2)
        #expect(check.pauses.count == 1)
        #expect(check.pauses.allSatisfy { (0.5...1).contains($0) })
    }

    @Test("each try waits at most 15 s for an answer, not the session's 60 s")
    func eachTryIsBounded() async throws {
        let check = try ReleaseCheckFixture([.release("99.0.0")])
        defer { check.cleanUp() }

        _ = await SelfUpdater(coordinatorBaseURL: check.coordinator, urlSession: check.session).checkForUpdate()

        #expect(check.requests.map(\.timeoutInterval) == [15])
    }

    @Test("a check that keeps failing on the way stops after 3 tries, pausing longer each time, and says why")
    func failuresOnTheWayStopAfterThreeTries() async throws {
        let check = try ReleaseCheckFixture([.fail(.networkConnectionLost), .fail(.cannotConnectToHost), .fail(.timedOut)])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .checkFailed(let reason) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(reason == "\(check.host) didn't answer within 15 s (3 tries)")
        #expect(check.requests.count == 3)
        // Equal jitter on a doubling base: 0.5 to 1 s, then 1 to 2 s.
        #expect(check.pauses.count == 2)
        if check.pauses.count == 2 {
            #expect((0.5...1).contains(check.pauses[0]))
            #expect((1...2).contains(check.pauses[1]))
        }
    }

    @Test("an answer from the coordinator is final, a refusal included", arguments: [
        ScriptedReleaseProtocol.Step.answer(status: 500, body: "boom"),
        .answer(status: 404, body: ""),
        .answer(status: 200, body: "[]"),
        .release("99.0.0", platform: "linux-x86_64"),
        .fail(.badServerResponse),
    ])
    func answersAreNotAskedAgain(step: ScriptedReleaseProtocol.Step) async throws {
        let check = try ReleaseCheckFixture([step, .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .checkFailed = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(check.requests.count == 1)
        #expect(check.pauses.isEmpty)
    }

    @Test("a coordinator that never answers is given up after each try's bound", .timeLimit(.minutes(1)))
    func silentCoordinatorIsGivenUp() async throws {
        let peer = try SilentPeer()
        let port = try await peer.start()
        defer { peer.stop() }
        let check = try ReleaseCheckFixture([])
        defer { check.cleanUp() }
        // Without a bound of its own, a try waits for the session's.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let pauses = check.recordedPauses
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:\(port)", installRoot: check.root, verifyCodeSignatures: false,
            currentVersion: "1.0.0", urlSession: URLSession(configuration: configuration), now: { 1_000 },
            releaseCheck: .init(attempts: 2, requestTimeout: 1, pause: { pauses.record($0) }))

        let started = ContinuousClock.now
        let result = await updater.checkForUpdate()
        let elapsed = ContinuousClock.now - started

        guard case .checkFailed(let reason) = result else {
            Issue.record("a coordinator that never answers gave \(result)")
            return
        }
        #expect(reason == "127.0.0.1:\(port) didn't answer within 1 s (2 tries)")
        #expect(peer.acceptedCount >= 2)
        #expect(elapsed < .seconds(6))
    }

    @Test("`update` reports a failed check as a failed check and downloads nothing")
    func updateReportsTheFailedCheck() async throws {
        let check = try ReleaseCheckFixture([.fail(.timedOut), .fail(.timedOut), .fail(.timedOut), .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().update()

        guard case .checkFailed(let reason) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(reason == "\(check.host) didn't answer within 15 s (3 tries)")
        #expect(check.requests.map { $0.url?.path } == Array(repeating: "/v1/releases/latest", count: 3))
    }
}

/// One test's coordinator (a host of its own, answered by `ScriptedReleaseProtocol`) and a temporary install root.
private struct ReleaseCheckFixture {
    let host: String
    let root: URL
    let session = ScriptedReleaseProtocol.session()
    let recordedPauses = RecordedPauses()

    var coordinator: String { "https://\(host)" }
    var requests: [URLRequest] { ScriptedReleaseProtocol.requests(to: host) }
    var pauses: [TimeInterval] { recordedPauses.all }

    init(_ steps: [ScriptedReleaseProtocol.Step]) throws {
        host = ScriptedReleaseProtocol.host(answering: steps)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The updater of a 1.0.0 install in `root`: the standard tries and bound, its pauses recorded instead of slept.
    func updater() -> SelfUpdater {
        let pauses = recordedPauses
        return SelfUpdater(
            coordinatorBaseURL: coordinator, installRoot: root, verifyCodeSignatures: false, currentVersion: "1.0.0",
            urlSession: session, now: { 1_000 }, releaseCheck: .init(pause: { pauses.record($0) }))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class RecordedPauses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { lock.withLock { values.append(seconds) } }
    var all: [TimeInterval] { lock.withLock { values } }
}

/// Answers each request to a host with the next step of that host's script, and keeps the requests.
final class ScriptedReleaseProtocol: URLProtocol, @unchecked Sendable {
    enum Step: Sendable, CustomTestStringConvertible {
        case fail(URLError.Code)
        case answer(status: Int, body: String)

        static func release(_ version: String, platform: String = "macos-arm64") -> Step {
            .answer(status: 200, body: #"{"version":"\#(version)","platform":"\#(platform)","url":"https://downloads.invalid/darkbloom-\#(version).tar.gz","bundle_hash":"\#(String(repeating: "a", count: 64))"}"#)
        }

        var testDescription: String {
            switch self {
            case .fail(let code): return "fails with URLError \(code.rawValue)"
            case .answer(let status, let body): return "answers \(status) \(body.prefix(40))"
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [Step]] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    /// A new host whose requests are answered by `steps`, in order.
    static func host(answering steps: [Step]) -> String {
        let host = "release-check-\(UUID().uuidString.lowercased()).invalid"
        lock.withLock { scripts[host] = steps }
        return host
    }

    static func requests(to host: String) -> [URLRequest] {
        lock.withLock { seen[host] ?? [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedReleaseProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let step = Self.lock.withLock { () -> Step? in
            Self.seen[host, default: []].append(request)
            guard let next = Self.scripts[host]?.first else { return nil }
            Self.scripts[host]?.removeFirst()
            return next
        }
        switch step {
        case .fail(let code)?:
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .answer(let status, let body)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }

    override func stopLoading() {}
}
