import Foundation
import Testing
@testable import ProviderCore

/// "None of the steps worked" (`solo-steps-failed.md`): single-Mac serving a 0.10.8 updater restarted keeps a started
/// pair down, and the ends it causes set the Darkbloom approval aside for an hour.
@Suite("Single-Mac serving steps aside for a started pair, and its blocked ends don't count", .serialized)
struct SoloStepsStickTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("solo-choice-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("an update, a login or a watchdog revival that restarts unchosen single-Mac serving: it steps aside for the started pair")
    func unchosenStepsAside() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A Mac updated from 0.10.8 has no choice recorded: the started pair, wanting this Mac's part, wins.
        #expect(ClusterSoloChoice.chosenAt(in: dir) == nil)
        #expect(ClusterSoloChoice.stepsAside(wantedKey: "cluster:84377e741989", chosenAt: ClusterSoloChoice.chosenAt(in: dir)))
        #expect(ClusterSoloChoice.stepsAside(wantedKey: "cluster:84377e741989:local-only@127.0.0.1", chosenAt: nil))
    }

    @Test("the person's own choice of single-Mac serving stands until the pair is started or `stop --solo` runs here")
    func chosenStays() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        ClusterSoloChoice.record(in: dir, now: 1_000)
        #expect(ClusterSoloChoice.chosenAt(in: dir) == 1_000)
        #expect(!ClusterSoloChoice.stepsAside(wantedKey: "cluster:abc", chosenAt: ClusterSoloChoice.chosenAt(in: dir)))
        ClusterSoloChoice.clear(in: dir)
        #expect(ClusterSoloChoice.stepsAside(wantedKey: "cluster:abc", chosenAt: ClusterSoloChoice.chosenAt(in: dir)))
    }

    @Test("it never fights \"the pair isn't running: serve alone\": no part wanted, or the degraded server, never steps aside")
    func neverFightsServingAlone() {
        #expect(!ClusterSoloChoice.stepsAside(wantedKey: nil, chosenAt: nil))
        #expect(!ClusterSoloChoice.stepsAside(wantedKey: "solo:EigenLabs/Qwen3.8-27B-4bit-mtp", chosenAt: nil))
    }

    @Test("status says why after a step aside, in the build's own command")
    func steppedAsideNote() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        ClusterSoloChoice.noteSteppedAside(.init(at: 0, pid: 68099), in: dir)
        let note = ClusterSoloChoice.steppedAside(in: dir)
        #expect(note == .init(at: 0, pid: 68099))
        let line = ClusterSoloChoice.line(note!, cli: "darkbloom-dev")
        #expect(line == "Single-Mac serving stepped aside for the pair at 1970-01-01T00:00:00Z (process 68099): the pair is started "
            + "here and nobody chose single-Mac serving since. `darkbloom-dev start --solo` serves this Mac alone again.")
        ClusterSoloChoice.record(in: dir) // A new choice clears the note.
        #expect(ClusterSoloChoice.steppedAside(in: dir) == nil)
    }

    @Test("a part ended by the held lock never counts toward serving locally (old API: the lock's words)")
    func lockEndsDoNotCount() {
        for words in ["a single-Mac Darkbloom provider (process 68099) is serving on this Mac; `darkbloom stop --solo` stops it",
                      "another update operation owns the lock (pid 9523, provider-instance)"] {
            #expect(ClusterApprovalCheck.memberQuickEnds(after: 2, ranSeconds: 3, lastError: words) == 2, "\(words)")
        }
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 2, ranSeconds: 3, lastError: "exit 1") == 3, "an ordinary quick end counts")
    }

    @Test("an end while either Mac's part is held back doesn't count; once the blocker clears, a failing set-aside goes")
    func heldBackAndClear() {
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 2, ranSeconds: 3, lastError: "closed", heldBack: true) == 2)
        #expect(ClusterApprovalCheck.clearsAfterBlocker(.failing))
        #expect(!ClusterApprovalCheck.clearsAfterBlocker(.withdrawn) && !ClusterApprovalCheck.clearsAfterBlocker(.unreachable))
    }
}
