/// `darkbloom update` on pair-2's MacBook (DevNet, 2026-11-07) failed twice with "download failed: update check failed:
/// The request timed out", a minute each, while the coordinator answered `curl` in 0.3 s: the release check sent one
/// request, waited the shared session's 60 s for an answer and never asked again. The coordinator here is answered
/// in-process, one scripted step per request (`ScriptedReleaseProtocol`), or is a loopback peer that takes the
/// connection and never answers (`SilentPeer`). Pauses and log lines are recorded instead of slept and written. Install
/// roots are temporary; nothing is downloaded or installed.

import Foundation
import Testing
@testable import ProviderCore

@Suite("Release check", .timeLimit(.minutes(1)))
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

    @Test("a failure on the way is asked again, whichever it is", arguments: [
        URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .notConnectedToInternet, .secureConnectionFailed,
    ])
    func everyFailureOnTheWayIsAskedAgain(code: URLError.Code) async throws {
        let check = try ReleaseCheckFixture([.fail(code), .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .updateAvailable = result else {
            Issue.record("URLError \(code.rawValue) wasn't asked again: \(result)")
            return
        }
        #expect(check.requests.count == 2)
        #expect(check.pauses.count == 1)
    }

    @Test("a check that keeps failing on the way stops after 3 tries, pausing longer each time, and says why")
    func failuresOnTheWayStopAfterThreeTries() async throws {
        let check = try ReleaseCheckFixture([.fail(.networkConnectionLost), .fail(.cannotConnectToHost), .fail(.timedOut)])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .checkFailed(let failure) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(failure == .init(.noAnswer, "\(check.host) didn't answer within 15 s (3 tries)"))
        #expect(check.requests.count == 3)
        // Equal jitter on a doubling base: 0.5 to 1 s, then 1 to 2 s.
        #expect(check.pauses.count == 2)
        if check.pauses.count == 2 {
            #expect((0.5...1).contains(check.pauses[0]))
            #expect((1...2).contains(check.pauses[1]))
        }
        #expect(check.lines.count == 3)
        #expect(check.lines.last?.hasSuffix("; giving up") == true, "\(check.lines)")
    }

    @Test("the count is of the tries made")
    func countIsOfTheTriesMade() async throws {
        let check = try ReleaseCheckFixture([.fail(.timedOut), .fail(.badServerResponse), .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .checkFailed(let failure) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(failure.reason.hasPrefix("couldn't reach \(check.host) (2 tries): "), "\(failure.reason)")
        #expect(check.requests.count == 2)
    }

    @Test("an answer is final, and says what was wrong with it, not the network", arguments: ReleaseCheckRefusal.all)
    func answersAreFinal(refusal: ReleaseCheckRefusal) async throws {
        let check = try ReleaseCheckFixture([refusal.step, .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .checkFailed(let failure) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(failure.cause == refusal.cause)
        if let reason = refusal.reason {
            #expect(failure.reason == reason.replacingOccurrences(of: "HOST", with: check.host))
        }
        #expect(check.requests.count == 1)
        #expect(check.pauses.isEmpty)
    }

    @Test("this Mac's own failures say so: its update record, its coordinator URL")
    func thisMacsFailures() async throws {
        let check = try ReleaseCheckFixture([.release("99.0.0")])
        defer { check.cleanUp() }
        let record = check.root.appendingPathComponent("recovery/state.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: record)

        guard case .checkFailed(let unreadable) = await check.updater().checkForUpdate() else {
            Issue.record("an unreadable update record didn't fail the check")
            return
        }
        #expect(unreadable.cause == .thisMac)
        #expect(unreadable.reason.hasPrefix("this Mac's update record can't be read (\(record.path)): "), "\(unreadable.reason)")
        #expect(check.requests.isEmpty)

        try FileManager.default.removeItem(at: record)
        let invalid = SelfUpdater(coordinatorBaseURL: "http://exa mple.invalid", installRoot: check.root,
                                  verifyCodeSignatures: false, currentVersion: "1.0.0", urlSession: check.session)
        guard case .checkFailed(let notAURL) = await invalid.checkForUpdate() else {
            Issue.record("a coordinator URL that isn't one didn't fail the check")
            return
        }
        #expect(notAURL == .init(.thisMac, "the coordinator URL isn't a valid URL"))
    }

    @Test("a cancelled try is not asked again")
    func cancelledTryIsFinal() async throws {
        let check = try ReleaseCheckFixture([.fail(.cancelled), .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().checkForUpdate()

        guard case .checkFailed = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(check.requests.count == 1)
        #expect(check.pauses.isEmpty)
    }

    @Test("a check cancelled during its pause asks nothing more")
    func cancelledDuringThePause() async throws {
        let check = try ReleaseCheckFixture([.fail(.timedOut), .release("99.0.0")])
        defer { check.cleanUp() }
        let updater = check.updater {
            let recorded = $0.pause
            $0.pause = { seconds in
                await recorded(seconds)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let result = await Task { await updater.checkForUpdate() }.value

        guard case .checkFailed(let failure) = result else {
            Issue.record("a check cancelled during its pause gave \(result)")
            return
        }
        #expect(failure == .init(.noAnswer, "\(check.host) didn't answer within 15 s"))
        #expect(check.requests.count == 1)
        #expect(check.pauses.count == 1)
    }

    @Test("after a failed try: another try, the next round, or none")
    func whatFollowsAFailedTry() {
        let standard = SelfUpdater.ReleaseCheck.standard, pair = SelfUpdater.ReleaseCheck.pairCycle
        let noAnswer = URLError(.timedOut)
        #expect(standard.next(after: noAnswer, tries: 1, round: 1, cancelled: false) == .askAgain)
        #expect(standard.next(after: noAnswer, tries: 2, round: 1, cancelled: false) == .askAgain)
        #expect(standard.next(after: noAnswer, tries: 3, round: 1, cancelled: false) == .stop)
        #expect(standard.next(after: noAnswer, tries: 1, round: 1, cancelled: true) == .stop)
        #expect(standard.next(after: URLError(.cancelled), tries: 1, round: 1, cancelled: false) == .stop)
        #expect(standard.next(after: CancellationError(), tries: 1, round: 1, cancelled: false) == .stop)
        #expect(pair.next(after: noAnswer, tries: 3, round: 1, cancelled: false) == .nextRound)
        #expect(pair.next(after: noAnswer, tries: 3, round: 1, cancelled: true) == .stop)
        #expect(pair.next(after: noAnswer, tries: 3, round: 2, cancelled: false) == .stop)
        #expect(pair.next(after: URLError(.badServerResponse), tries: 1, round: 1, cancelled: false) == .stop)
    }

    @Test("each failed try is logged with how it connected and what follows, and no URL")
    func failedTriesAreLogged() async throws {
        let check = try ReleaseCheckFixture([.fail(.timedOut), .fail(.cannotConnectToHost), .release("99.0.0")])
        defer { check.cleanUp() }

        guard case .updateAvailable = await check.updater().checkForUpdate() else {
            Issue.record("expected the release from the third try")
            return
        }

        #expect(check.lines.count == 2)
        let host = NSRegularExpression.escapedPattern(for: check.host)
        let tries = [(1, -1001), (2, -1004)].map { try? NSRegularExpression(pattern:
            #"^release check: try \#($0.0) of 3 to \#(host) failed after \d+\.\d s: NSURLErrorDomain \#($0.1) \([^)]+\); asking again in \d\.\d s$"#) }
        for (line, pattern) in zip(check.lines, tries) {
            #expect(pattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil, "\(line)")
        }
        #expect(check.lines.allSatisfy { !$0.contains("/v1/") && !$0.contains("platform=") && !$0.contains("://") })
    }

    @Test("a coordinator that never answers is given up after each try's bound")
    func silentCoordinatorIsGivenUp() async throws {
        let peer = try SilentPeer()
        let port = try await peer.start()
        defer { peer.stop() }
        let check = try ReleaseCheckFixture([])
        defer { check.cleanUp() }
        // Without a bound of its own, a try waits for the session's.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let updater = check.updater(baseURL: "http://127.0.0.1:\(port)", session: URLSession(configuration: configuration)) {
            $0.attempts = 2
            $0.requestTimeout = 1
        }

        let started = ContinuousClock.now
        let result = await updater.checkForUpdate()
        let elapsed = ContinuousClock.now - started

        guard case .checkFailed(let failure) = result else {
            Issue.record("a coordinator that never answers gave \(result)")
            return
        }
        #expect(failure == .init(.noAnswer, "127.0.0.1:\(port) didn't answer within 1 s (2 tries)"))
        #expect(peer.acceptedCount >= 2)
        #expect(elapsed < .seconds(6))
        // A real connection: the log says where each try got to.
        #expect(check.lines.count == 2)
        #expect(check.lines.allSatisfy { $0.contains("new connection, direct, 127.0.0.1:\(port)") }, "\(check.lines)")
    }

    @Test("`update` reports a failed check as a failed check and downloads nothing")
    func updateReportsTheFailedCheck() async throws {
        let check = try ReleaseCheckFixture([.fail(.timedOut), .fail(.timedOut), .fail(.timedOut), .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater().update()

        guard case .checkFailed(let failure) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(failure == .init(.noAnswer, "\(check.host) didn't answer within 15 s (3 tries)"))
        #expect(check.requests.map { $0.url?.path } == Array(repeating: "/v1/releases/latest", count: 3))
    }

    // MARK: - A pair's automatic cycle: one more round

    @Test("a pair's automatic check asks one more round, 1 to 2 minutes later, and finds the release")
    func pairCycleAsksAnotherRound() async throws {
        let check = try ReleaseCheckFixture([.fail(.timedOut), .fail(.timedOut), .fail(.timedOut), .release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater(rounds: 2).checkForUpdate()

        guard case .updateAvailable(_, let latest) = result else {
            Issue.record("expected the release from the second round, got \(result)")
            return
        }
        #expect(latest.version == "99.0.0")
        #expect(check.requests.count == 4)
        #expect(check.pauses.count == 3)
        if check.pauses.count == 3 {
            #expect((0.5...1).contains(check.pauses[0]))
            #expect((1...2).contains(check.pauses[1]))
            #expect((60...120).contains(check.pauses[2]))
        }
        #expect(check.lines.count == 3)
        #expect(check.lines.last?.contains("try 3 of 3, round 1 of 2, to \(check.host) failed") == true, "\(check.lines)")
        #expect(check.lines.last?.hasSuffix(", round 2 of 2") == true, "\(check.lines)")
    }

    @Test("a second round without an answer either gives up after 6 tries")
    func secondRoundGivesUp() async throws {
        let check = try ReleaseCheckFixture(Array(repeating: .fail(.timedOut), count: 6) + [.release("99.0.0")])
        defer { check.cleanUp() }

        let result = await check.updater(rounds: 2).checkForUpdate()

        guard case .checkFailed(let failure) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(failure == .init(.noAnswer, "\(check.host) didn't answer within 15 s (6 tries)"))
        #expect(check.requests.count == 6)
        #expect(check.pauses.count == 5)
        if check.pauses.count == 5 {
            #expect((60...120).contains(check.pauses[2]))
            #expect((0.5...1).contains(check.pauses[3]))
            #expect((1...2).contains(check.pauses[4]))
        }
    }

    @Test("an answer ends a pair's check at once")
    func answerEndsPairCycleCheck() async throws {
        let check = try ReleaseCheckFixture([.answer(status: 500, body: "boom"), .release("99.0.0")])
        defer { check.cleanUp() }

        guard case .checkFailed = await check.updater(rounds: 2).checkForUpdate() else {
            Issue.record("an HTTP error was asked again")
            return
        }
        #expect(check.requests.count == 1)
        #expect(check.pauses.isEmpty)
    }

    @Test("only a pair's automatic cycle asks a second round")
    func onlyAutomaticPairCyclesAskASecondRound() throws {
        #expect(SelfUpdater.ReleaseCheck.standard.rounds == 1)
        #expect(SelfUpdater.ReleaseCheck.pairCycle.rounds == 2)
        #expect(SelfUpdater.ReleaseCheck.pairCycle.roundPause == 60...120)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-check-service-\(UUID().uuidString)", isDirectory: true)
        func rounds(automatic: Bool) -> Int {
            ClusterPairUpdateCycle.Environment.live(serviceDirectory: directory, coordinatorURL: "https://coordinator.invalid",
                                                    automatic: automatic, log: { _ in }).updater.releaseCheck.rounds
        }
        #expect(rounds(automatic: true) == 2)
        #expect(rounds(automatic: false) == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Random pauses, and a bound on the tries

    /// Macs that lost the coordinator together don't ask again together, nor do a pair's two Macs start their second
    /// rounds together: each pause is drawn from its range. Here the source is injected and answers a quarter of the
    /// way into each range.
    @Test("each pause is drawn from its range, within a round and between rounds")
    func pausesAreDrawnFromTheirRanges() async throws {
        let check = try ReleaseCheckFixture(Array(repeating: .fail(.timedOut), count: 6))
        defer { check.cleanUp() }
        let ranges = Recorded<ClosedRange<TimeInterval>>()

        _ = await check.updater(rounds: 2) {
            $0.random = { range in
                ranges.record(range)
                return range.lowerBound + (range.upperBound - range.lowerBound) / 4
            }
        }.checkForUpdate()

        #expect(ranges.all == [0.5...1, 1...2, 60...120, 0.5...1, 1...2])
        #expect(check.pauses == [0.625, 1.25, 75, 0.625, 1.25])
    }

    @Test("the pauses' own source draws across each range and stays inside it")
    func pausesSpreadAcrossTheirRanges() {
        for releaseCheck in [SelfUpdater.ReleaseCheck.standard, .pairCycle] {
            for range: ClosedRange<TimeInterval> in [0.5...1, 1...2, 60...120] {
                let draws = (0..<200).map { _ in releaseCheck.random(range) }
                #expect(draws.allSatisfy { range.contains($0) }, "\(range): \(draws)")
                // 200 uniform draws spread over less than half their range: about once in 10^58 runs.
                let spread = (draws.max() ?? 0) - (draws.min() ?? 0)
                #expect(spread > (range.upperBound - range.lowerBound) / 2, "\(range): \(draws)")
            }
        }
    }

    /// `UpdateCheckCommandTests` spun for 1 h 50 min in a review's run, under a mutant whose rounds never ended: its
    /// coordinator fails every try at once and its updater doesn't pause, so only the decision could end the check. The
    /// tries of its rounds bound a check whatever the decision. The stand-in here keeps asking, but stops by itself
    /// after 100 tries, so this test ends either way.
    @Test("a check whose every decision is to ask again still stops after its rounds' tries",
          arguments: [SelfUpdater.ReleaseCheck.Next.askAgain, .nextRound])
    func triesAreBoundedWhateverTheDecision(decision: SelfUpdater.ReleaseCheck.Next) async throws {
        let check = try ReleaseCheckFixture(Array(repeating: .fail(.timedOut), count: 100))
        defer { check.cleanUp() }
        let decided = Recorded<SelfUpdater.ReleaseCheck.Next>()
        let updater = check.updater(rounds: 2) {
            $0.nextForTesting = { next in
                decided.record(next)
                return decided.all.count < 100 ? decision : .stop
            }
        }
        #expect(updater.releaseCheck.maximumTries == 6)
        #expect(SelfUpdater.ReleaseCheck.standard.maximumTries == 3)

        let result = await updater.checkForUpdate()

        guard case .checkFailed(let failure) = result else {
            Issue.record("expected a failed check, got \(result)")
            return
        }
        #expect(failure == .init(.noAnswer, "\(check.host) didn't answer within 15 s (6 tries)"))
        #expect(check.requests.count == 6)
        #expect(check.pauses.count == 5)
        #expect(check.lines.count == 6)
        #expect(check.lines.last?.hasSuffix("; giving up") == true, "\(check.lines.suffix(1))")
    }
}

/// A coordinator's answer that isn't a release this Mac can use, and what the check says about it (`HOST` stands for
/// the coordinator's host; nil: not compared).
struct ReleaseCheckRefusal: Sendable, CustomTestStringConvertible {
    let step: ScriptedReleaseProtocol.Step
    let cause: UpdateCheckFailure.Cause
    let reason: String?

    var testDescription: String { step.testDescription }

    static let all: [ReleaseCheckRefusal] = [
        .init(step: .answer(status: 500, body: "boom"), cause: .badAnswer,
              reason: "HOST answered HTTP 500 instead of the latest release"),
        .init(step: .answer(status: 404, body: ""), cause: .badAnswer,
              reason: "HOST answered HTTP 404 instead of the latest release"),
        .init(step: .answer(status: 200, body: "not json"), cause: .badAnswer,
              reason: "HOST's answer isn't a release: it isn't JSON"),
        .init(step: .answer(status: 200, body: "[]"), cause: .badAnswer,
              reason: "HOST's answer isn't a release: it isn't a JSON object"),
        .init(step: .answer(status: 200, body: #"{"version":"99.0.0"}"#), cause: .badAnswer,
              reason: "HOST's answer isn't a release: it has no version, platform or download URL"),
        .init(step: .release("99.0.0", platform: "linux-x86_64"), cause: .badAnswer,
              reason: "HOST's latest release is for another platform (linux-x86_64), not this Mac's (macos-arm64)"),
        .init(step: .answer(status: 200, body: #"{"version":"99.0.0","platform":"macos-arm64","url":"https://downloads.invalid/x.tar.gz"}"#),
              cause: .badAnswer, reason: "HOST's latest release has no bundle hash"),
        .init(step: .release("ninety-nine"), cause: .badAnswer,
              reason: "HOST's latest release has a version this Mac can't read (ninety-nine)"),
        .init(step: .fail(.badServerResponse), cause: .noAnswer, reason: nil),
    ]
}

/// One test's coordinator (a host of its own, answered by `ScriptedReleaseProtocol`), a temporary install root, and
/// what its updaters' checks paused for and logged.
private struct ReleaseCheckFixture {
    let host: String
    let root: URL
    let session = ScriptedReleaseProtocol.session()
    let recordedPauses = Recorded<TimeInterval>()
    let recordedLines = Recorded<String>()

    var coordinator: String { "https://\(host)" }
    var requests: [URLRequest] { ScriptedReleaseProtocol.requests(to: host) }
    var pauses: [TimeInterval] { recordedPauses.all }
    var lines: [String] { recordedLines.all }

    init(_ steps: [ScriptedReleaseProtocol.Step]) throws {
        host = ScriptedReleaseProtocol.host(answering: steps)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The updater of a 1.0.0 install in `root`: the standard check, in `rounds` rounds, its pauses and log lines
    /// recorded instead of slept and written, then `configure`d.
    func updater(baseURL: String? = nil, session: URLSession? = nil, rounds: Int = 1,
                 _ configure: (inout SelfUpdater.ReleaseCheck) -> Void = { _ in }) -> SelfUpdater {
        let (pauses, lines) = (recordedPauses, recordedLines)
        var releaseCheck = SelfUpdater.ReleaseCheck(rounds: rounds, pause: { pauses.record($0) }, log: { lines.record($0) })
        configure(&releaseCheck)
        return SelfUpdater(
            coordinatorBaseURL: baseURL ?? coordinator, installRoot: root, verifyCodeSignatures: false,
            currentVersion: "1.0.0", urlSession: session ?? self.session, now: { 1_000 }, releaseCheck: releaseCheck)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func record(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
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
