import Darwin
import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Account link NDJSON decoding")
struct AccountLinkEventDecodingTests {
    private func line(_ json: String) throws -> AccountLinkEvent {
        try AccountLinkEventDecoding.decode(line: json)
    }

    @Test("Decodes the three pinned event shapes")
    func decodesKnownEvents() throws {
        #expect(try line(#"{"event":"code","user_code":"ABCD-EFGH","verification_uri":"https://app.darkbloom.dev/link","expires_in":900}"#)
            == .code(userCode: "ABCD-EFGH", verificationURI: "https://app.darkbloom.dev/link", expiresIn: 900))
        #expect(try line(#"{"event":"linked"}"#) == .linked)
        #expect(try line(#"{"event":"error","message":"Device code expired. Run 'darkbloom login' again."}"#)
            == .error(message: "Device code expired. Run 'darkbloom login' again."))
    }

    @Test("Key order and numeric width don't matter")
    func decodesReorderedKeys() throws {
        #expect(try line(#"{"expires_in":5,"verification_uri":"https://x.test","user_code":"WXYZ-1234","event":"code"}"#)
            == .code(userCode: "WXYZ-1234", verificationURI: "https://x.test", expiresIn: 5))
    }

    @Test("Terminality: only linked/error end a stream")
    func terminalFlags() throws {
        #expect(try !line(#"{"event":"code","user_code":"A","verification_uri":"u","expires_in":1}"#).isTerminal)
        #expect(try line(#"{"event":"linked"}"#).isTerminal)
        #expect(try line(#"{"event":"error","message":"m"}"#).isTerminal)
    }

    @Test("Garbage, unknown kinds, and missing fields are rejected")
    func rejectsMalformedLines() {
        for bad in [
            "not json",
            #"{"event":"poll"}"#,
            #"{"event":"code","user_code":"ABCD-EFGH"}"#,
            #"{"event":"code","user_code":"ABCD-EFGH","verification_uri":"https://x.test","expires_in":"900"}"#,
            #"{"event":"error"}"#,
            #"{"user_code":"ABCD-EFGH"}"#,
        ] {
            #expect(throws: AccountLinkEventDecodeError.self) {
                try AccountLinkEventDecoding.decode(line: bad)
            }
        }
    }
}

@Suite("Account link CLI subprocess", .serialized)
struct AccountLinkCLITests {
    /// A throwaway executable shell script standing in for `darkbloom`. The
    /// locator/runner idiom lets tests point the adapter at /bin/sh-style
    /// fakes without touching installed tools.
    private struct ScriptCLILocator: DarkbloomCLILocating {
        let url: URL
        func locate() -> URL? { url }
    }

    private func makeScript(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-link-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-darkbloom")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func collect(_ cli: ProcessAccountLinkCLI) async throws -> [AccountLinkEvent] {
        var events: [AccountLinkEvent] = []
        for try await event in cli.linkEvents() {
            events.append(event)
        }
        return events
    }

    @Test("Streams a code event then linked, then finishes")
    func streamsHappyPath() async throws {
        let script = try makeScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"code","user_code":"REAL-1234","verification_uri":"https://example.test/link","expires_in":600}'
        printf '%s\\n' '{"event":"linked"}'
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let events = try await collect(ProcessAccountLinkCLI(locator: ScriptCLILocator(url: script)))

        #expect(events == [
            .code(userCode: "REAL-1234", verificationURI: "https://example.test/link", expiresIn: 600),
            .linked,
        ])
    }

    @Test("A terminal error event is delivered as data even though the CLI exits non-zero")
    func streamsErrorEventThenFailureExit() async throws {
        let script = try makeScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"code","user_code":"REAL-1234","verification_uri":"https://example.test/link","expires_in":600}'
        printf '%s\\n' '{"event":"error","message":"Device code expired. Run darkbloom login again."}'
        printf '%s\\n' 'Device code expired. Run darkbloom login again.' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let events = try await collect(ProcessAccountLinkCLI(locator: ScriptCLILocator(url: script)))

        #expect(events.count == 2)
        guard case .error(let message) = events.last else {
            Issue.record("unexpected events: \(events)")
            return
        }
        #expect(message.contains("expired"))
    }

    @Test("Non-zero exit without any event throws the stderr-derived failure")
    func throwsOnSilentFailure() async throws {
        let script = try makeScript("""
        #!/bin/sh
        echo 'unknown option: --json' >&2
        exit 2
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        do {
            _ = try await collect(ProcessAccountLinkCLI(locator: ScriptCLILocator(url: script)))
            Issue.record("expected a non-zero exit error")
        } catch let error as ProviderCLIError {
            guard case .exited(2, let message) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(message.contains("unknown option"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("An unparseable line fails the stream instead of being skipped")
    func throwsOnGarbageLine() async throws {
        let script = try makeScript("""
        #!/bin/sh
        printf '%s\\n' 'this is not ndjson'
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        do {
            _ = try await collect(ProcessAccountLinkCLI(locator: ScriptCLILocator(url: script)))
            Issue.record("expected a decode failure")
        } catch let error as AccountLinkEventDecodeError {
            #expect(error.line.contains("not ndjson"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("Missing CLI surfaces cliNotFound without exec attempts")
    func missingCLI() async {
        struct NoCLI: DarkbloomCLILocating {
            func locate() -> URL? { nil }
        }
        do {
            _ = try await collect(ProcessAccountLinkCLI(locator: NoCLI()))
            Issue.record("expected cliNotFound")
        } catch let error as ProviderCLIError {
            #expect(error == .cliNotFound)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("Cancelling the consumer terminates the child process")
    func cancellationTerminatesChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-link-cli-pid-\(UUID().uuidString)")
        let script = try makeScript("""
        #!/bin/sh
        printf '%s\\n' '{"event":"code","user_code":"REAL-1234","verification_uri":"https://example.test/link","expires_in":600}'
        echo $$ >\(pidFile.path)
        sleep 60
        """)
        defer {
            try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pidFile)
        }

        let cli = ProcessAccountLinkCLI(locator: ScriptCLILocator(url: script))
        let collector = EventCollector()
        let consumer = Task {
            do {
                for try await event in cli.linkEvents() {
                    await collector.append(event)
                }
            } catch {
                // Cancellation ends the iteration without throwing; anything
                // thrown here is out of scope for this test.
            }
        }

        // Wait until the child is definitely running (pid file written) AND
        // the consumer has appended the code event — otherwise racing the
        // cancel could cut the stream before any event lands.
        let pidDeadline = ContinuousClock.now + .seconds(10)
        var childPID: Int32 = 0
        while ContinuousClock.now < pidDeadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               await collector.count >= 1 {
                childPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard childPID > 0 else {
            Issue.record("child never started (or code event never consumed)")
            return
        }

        consumer.cancel()
        _ = await consumer.value

        // The consumer saw the code (and only the code): cancellation cuts the
        // stream before any further output is consumed.
        #expect(await collector.events == [.code(userCode: "REAL-1234", verificationURI: "https://example.test/link", expiresIn: 600)])

        // And the child must be dead shortly after (not left for 60 s).
        let deathDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deathDeadline {
            if kill(childPID, 0) != 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("child process survived stream cancellation")
    }
}

/// Observed events from a consuming task, shared across the cancellation race.
private actor EventCollector {
    private(set) var events: [AccountLinkEvent] = []

    var count: Int { events.count }

    func append(_ event: AccountLinkEvent) {
        events.append(event)
    }
}
