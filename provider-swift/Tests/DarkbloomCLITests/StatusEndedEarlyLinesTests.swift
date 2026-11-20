import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom status` lists the requests that ended early by what stopped them and whether the coordinator pays for
/// them. A daemon that keeps no causes (an older one) still gets the single note on which cases are paid.
@Suite("Status: requests that ended early")
struct StatusEndedEarlyLinesTests {
    private static let footer =
        "  Paid jobs are listed under Earnings in the console; requests to your own machine are free."

    private func lines(served: UInt64, endedEarly: UInt64, byCause: EndedEarlyCounts?) throws -> [String] {
        let now = Date().timeIntervalSince1970
        let state = try CLICommandSandbox.runningState(now: now, stats: DaemonState.Stats(
            requestsServed: served, tokensGenerated: 10_255_565,
            cancellationsPartialComplete: endedEarly, endedEarly: byCause))
        return Status.servedRequestLines(state: state, now: now)
    }

    @Test func eachCauseHasItsLineAndSaysWhetherItIsPaid() throws {
        var counts = EndedEarlyCounts()
        counts.requesterLeftPaid = 4
        counts.stoppedOnThisMac = 1
        counts.anotherMacFirst = 1
        counts.connectionLost = 1
        #expect(try lines(served: 68_341, endedEarly: 7, byCause: counts) == [
            "Requests served since the daemon started (1h1m ago): 68341  |  output tokens: 10255565",
            "  7 of them ended early:",
            "    4 paid for the work done: the requester left mid-answer",
            "    1 paid for the work done: stopped on this Mac (a drain or an add-on hold)",
            "    1 unpaid: another Mac answered first",
            "    1 unpaid: the connection to the network dropped",
            Self.footer,
        ])
    }

    @Test func everyOtherCauseHasItsLineToo() throws {
        var counts = EndedEarlyCounts()
        counts.otherPaid = 1
        counts.startedTooLate = 2
        counts.otherUnpaid = 3
        #expect(try lines(served: 100, endedEarly: 6, byCause: counts) == [
            "Requests served since the daemon started (1h1m ago): 100  |  output tokens: 10255565",
            "  6 of them ended early:",
            "    1 paid for the work done: stopped by the network",
            "    2 unpaid: this Mac started too late",
            "    3 unpaid: stopped by the network for another reason",
            Self.footer,
        ])
    }

    /// Today's coordinator sends no reason with its cancel: those keep the note that says which cases are paid,
    /// while the causes this Mac knows itself keep their own lines.
    @Test func cancelsWithoutAReasonShareTheNote() throws {
        var counts = EndedEarlyCounts()
        counts.noReason = 2
        counts.connectionLost = 1
        #expect(try lines(served: 372, endedEarly: 3, byCause: counts) == [
            "Requests served since the daemon started (1h1m ago): 372  |  output tokens: 10255565",
            "  3 of them ended early:",
            "    1 unpaid: the connection to the network dropped",
            "    2 stopped by the network: paid for the work done if the requester left mid-answer,",
            "      unpaid if another Mac answered first or this Mac started too late",
            Self.footer,
        ])
    }

    @Test func aDaemonWithoutCausesKeepsTheSingleNote() throws {
        #expect(try lines(served: 1_722, endedEarly: 2, byCause: nil) == [
            "Requests served since the daemon started (1h1m ago): 1722  |  output tokens: 10255565",
            "  2 of them ended early: paid for the work done if the requester left mid-answer,",
            "  unpaid if another Mac answered first, this Mac started too late or lost its connection.",
            Self.footer,
        ])
    }

    @Test func noEarlyEndNoLines() throws {
        #expect(try lines(served: 12, endedEarly: 0, byCause: EndedEarlyCounts()) == [
            "Requests served since the daemon started (1h1m ago): 12  |  output tokens: 10255565",
            Self.footer,
        ])
    }
}
