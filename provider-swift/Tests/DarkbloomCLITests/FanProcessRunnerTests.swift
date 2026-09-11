import Foundation
import Testing

@testable import darkbloom

/// Regression coverage for the `doctor` / `verify` hang reported in #811.
///
/// `LocalContentionSnapshot.runCapture` used to wait on the child before
/// draining its pipe, so a child that wrote past the ~64 KiB Darwin pipe buffer
/// blocked in `write(2)` while the parent blocked in `waitUntilExit()`. On the
/// reporter's Mac `/bin/ps -axo comm=` emitted 78,689 bytes and both commands
/// hung until interrupted.
///
/// `.serialized` because `FanProcessRunner` drains through
/// `FileHandle.readabilityHandler`, and Foundation runs every file handle's
/// handler on one process-wide serial queue. Run in parallel, these cases jam
/// that queue for each other: a trivial `echo` child took 20s and the two
/// chatty cases never returned, because clearing the handler at the end of
/// `run` waits on the same queue. Nothing in production runs two of these at
/// once -- `doctor` probes sequentially -- so serializing the suite is the
/// honest shape, not a workaround for a live defect.
@Suite("Fan process runner", .serialized)
struct FanProcessRunnerTests {
    /// The pre-fix `runCapture` blocks in a syscall, which a swift-testing
    /// `.timeLimit` (a `Task` cancellation) cannot interrupt. Running it
    /// off-thread and joining on a semaphore keeps a reintroduced deadlock a
    /// *named* failure instead of a wedged test bundle.
    private final class Box: @unchecked Sendable {
        var value: String?
    }

    @Test("runCapture survives a child that outruns the pipe buffer")
    func runCaptureSurvivesChattyChild() {
        // 200_000 bytes has to exceed the 64 KiB pipe buffer, or this passes
        // against the unfixed implementation.
        let args = ["-c", "yes darkbloom | head -c 200000"]
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = LocalContentionSnapshot.runCapture("/bin/sh", args: args)
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            Issue.record("runCapture deadlocked on a child larger than the pipe buffer")
            return
        }
        #expect(box.value?.contains("darkbloom") == true)
    }

    /// `ps -axo comm=` was 78,689 bytes on the reporter's machine, so a probe
    /// capped at the runner's 64 KiB default would drop every process name past
    /// the cap and report "no competitors" on exactly the busy Macs #811 is
    /// about.
    @Test("the contention probe keeps process names past the runner's default cap")
    func runCaptureKeepsOutputPastTheDefaultCap() {
        let args = ["-c", "yes darkbloom | head -c 200000; echo ollama"]
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = LocalContentionSnapshot.runCapture("/bin/sh", args: args)
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            Issue.record("runCapture deadlocked on a child larger than the pipe buffer")
            return
        }
        #expect(box.value?.contains("ollama") == true)
    }

    @Test("other callers keep the 64 KiB default bound")
    func defaultOutputCapIsUnchanged() {
        let result = FanProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "yes darkbloom | head -c 200000"]
        )
        #expect(result.output.utf8.count == 64 * 1024)
    }

    @Test("a chatty child is still bounded by the runner deadline")
    func runCaptureReturnsNilWhenTheChildNeverExits() {
        // A child that holds stdout open forever is what draining alone does not
        // fix: `readDataToEndOfFile()` waits for EOF. The deadline is what makes
        // a best-effort probe bounded, which is what #811 asks for.
        let args = ["-c", "sleep 120"]
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = LocalContentionSnapshot.runCapture("/bin/sh", args: args)
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else {
            Issue.record("runCapture never returned for a child that outlives the deadline")
            return
        }
        #expect(box.value == nil)
    }

    @Test("stderr is discarded when the caller only text-matches stdout")
    func stderrIsDiscarded() {
        let result = FanProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2"],
            discardStandardError: true
        )
        #expect(result.output.contains("out"))
        #expect(!result.output.contains("err"))
    }

    @Test("stderr is folded into the output by default")
    func stderrIsMergedByDefault() {
        let result = FanProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2"]
        )
        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
    }

    @Test("a spawn failure is reported as a failure, not as empty output")
    func spawnFailureIsDistinguishable() {
        let result = FanProcessRunner.run("/nonexistent/darkbloom-probe", arguments: [])
        #expect(result.status == -1)
        #expect(LocalContentionSnapshot.runCapture("/nonexistent/darkbloom-probe", args: []) == nil)
    }
}
