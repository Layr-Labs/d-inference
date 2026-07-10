import XCTest
@testable import ProviderCore

final class TerminalJournalTests: XCTestCase {
    func entry(_ attempt: String, _ digest: String) -> TerminalJournalEntry {
        TerminalJournalEntry(
            terminalDigest: digest,
            jobId: "j",
            attemptId: attempt,
            leaseId: "l",
            outcome: "completed",
            promptTokens: 1,
            completionTokens: 1,
            responseHash: "rh",
            seSignature: "sig"
        )
    }

    func testConflictOnDigestMismatch() throws {
        let j = TerminalJournal(capacity: 10)
        try j.append(entry("a1", "d1"))
        XCTAssertThrowsError(try j.append(entry("a1", "d2"))) { err in
            XCTAssertEqual(err as? TerminalJournalError, .conflict)
        }
    }

    func testAckAndReplay() throws {
        let j = TerminalJournal(capacity: 10)
        try j.append(entry("a1", "d1"))
        XCTAssertTrue(j.ack(attemptId: "a1", terminalDigest: "d1", disposition: "settled"))
        XCTAssertTrue(j.unacked().isEmpty)
        try j.append(entry("a1", "d1"))
        XCTAssertTrue(j.ack(attemptId: "a1", terminalDigest: "d1", disposition: "settled"))
    }

    func testFullRejects() throws {
        let j = TerminalJournal(capacity: 1)
        try j.append(entry("a1", "d1"))
        XCTAssertThrowsError(try j.append(entry("a2", "d2"))) { err in
            XCTAssertEqual(err as? TerminalJournalError, .full)
        }
    }
}
