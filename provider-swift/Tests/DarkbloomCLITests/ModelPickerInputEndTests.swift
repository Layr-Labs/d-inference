import Darwin
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The picker reads key presses until the operator confirms or cancels. When
/// its input ends instead (the terminal went away, or the descriptor is no
/// longer readable) no key can arrive, so the picker has to cancel. A read
/// that only failed for the moment must still be retried.
///
/// Each case runs in a child process with a deadline. A picker that keeps
/// reading ends the child with SIGALRM, which fails the case instead of
/// blocking the test run.
@Suite("Start TUI model picker when its input ends")
struct ModelPickerInputEndTests {
    @Test("end of input cancels, even with a model selected, and shows the cursor again")
    func endOfInputCancels() async {
        await #expect(processExitsWith: .success) {
            alarm(pickerDeadlineSeconds)
            var pipeEnds: [Int32] = [-1, -1]
            try #require(pipe(&pipeEnds) == 0)
            close(pipeEnds[1])

            let run = try runPickerUntilItReturns(inputFD: pipeEnds[0])

            #expect(run.selection == [])
            #expect(run.output.contains("1 selected"))
            #expect(run.output.hasSuffix("\u{1B}[?25h"))
        }
    }

    @Test("a read error that cannot clear cancels")
    func permanentReadErrorCancels() async {
        await #expect(processExitsWith: .success) {
            alarm(pickerDeadlineSeconds)
            // Every read from a descriptor that is not open fails with EBADF.
            let run = try runPickerUntilItReturns(inputFD: -1)

            #expect(run.selection == [])
            #expect(run.output.hasSuffix("\u{1B}[?25h"))
        }
    }

    @Test("a terminal that hangs up while the picker waits cancels, and its mode is restored")
    func terminalHangUpCancelsAndRestoresMode() async {
        await #expect(processExitsWith: .success) {
            alarm(pickerDeadlineSeconds)
            var master: Int32 = -1
            var slave: Int32 = -1
            try #require(openpty(&master, &slave, nil, nil, nil) == 0)
            var cooked = termios()
            try #require(tcgetattr(slave, &cooked) == 0)
            cooked.c_lflag |= UInt(ECHO | ICANON | ISIG)
            try #require(tcsetattr(slave, TCSANOW, &cooked) == 0)

            // Close the terminal's other end once the picker has switched it
            // to raw mode and has had time to block in its read.
            let terminal = (master: master, slave: slave)
            Thread.detachNewThread {
                while localModes(of: terminal.slave) & UInt(ICANON) != 0 { usleep(1_000) }
                usleep(100_000)
                close(terminal.master)
            }

            let run = try runPickerUntilItReturns(inputFD: slave)

            #expect(run.selection == [])
            #expect(localModes(of: slave) == cooked.c_lflag)
        }
    }

    @Test("a read interrupted by a signal is retried, and the next key still counts")
    func interruptedReadIsRetried() async {
        await #expect(processExitsWith: .success) {
            alarm(pickerDeadlineSeconds)
            // No SA_RESTART, so the signal makes the blocked read fail with EINTR.
            var interrupt = sigaction()
            interrupt.__sigaction_u.__sa_handler = { _ in }
            try #require(sigaction(SIGUSR1, &interrupt, nil) == 0)

            var sockets: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets) == 0)
            nonisolated(unsafe) let reader = pthread_self()
            let keyboard = sockets[1]
            Thread.detachNewThread {
                usleep(200_000)
                pthread_kill(reader, SIGUSR1)
                usleep(200_000)
                press(enterKey, on: keyboard)
            }

            let run = try runPickerUntilItReturns(inputFD: sockets[0])

            #expect(run.selection == [0])
        }
    }

    @Test("a descriptor with nothing to read yet is waited on without spinning")
    func emptyNonBlockingInputIsWaitedOn() async {
        await #expect(processExitsWith: .success) {
            alarm(pickerDeadlineSeconds)
            var sockets: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets) == 0)
            try #require(fcntl(sockets[0], F_SETFL, fcntl(sockets[0], F_GETFL) | O_NONBLOCK) == 0)
            let keyboard = sockets[1]
            Thread.detachNewThread {
                usleep(500_000)
                press(enterKey, on: keyboard)
            }

            let processorSecondsBefore = processorSecondsUsed()
            let run = try runPickerUntilItReturns(inputFD: sockets[0])
            let processorSeconds = processorSecondsUsed() - processorSecondsBefore

            #expect(run.selection == [0])
            // A loop that retried without waiting would use about half a second.
            #expect(processorSeconds < 0.2, "used \(processorSeconds) s of processor time while waiting")
        }
    }
}

/// Long enough for a loaded machine, short enough that a picker which never
/// returns fails the case quickly.
private let pickerDeadlineSeconds: UInt32 = 20

private let enterKey: [UInt8] = [0x0D]

private struct PickerRun {
    let selection: [Int]
    let output: String
}

/// Runs the picker over one downloaded model that fits, which starts selected.
/// The picker draws to a temporary file.
private func runPickerUntilItReturns(inputFD: Int32) throws -> PickerRun {
    let id = "fixture/ready"
    let entries = [
        Start.PickerEntry(
            id: id,
            catalogModel: CatalogModel(id: id, s3Name: id, displayName: "Ready", sizeGb: 4),
            displayName: "Ready",
            sizeGb: 4,
            minRamGb: nil,
            downloaded: true,
            resumable: false)
    ]
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("model-picker-input-end-\(UUID().uuidString).out")
    let outputFD = open(outputURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    try #require(outputFD >= 0)
    defer {
        close(outputFD)
        try? FileManager.default.removeItem(at: outputURL)
    }
    let selection = try Start.parse([]).runModelPicker(
        entries: entries, memoryGb: 32, inputFD: inputFD, outputFD: outputFD)
    return PickerRun(
        selection: selection,
        output: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self))
}

private func press(_ key: [UInt8], on descriptor: Int32) {
    _ = key.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
}

private func localModes(of terminal: Int32) -> tcflag_t {
    var mode = termios()
    _ = tcgetattr(terminal, &mode)
    return mode.c_lflag
}

/// User plus system processor time this process has used so far.
private func processorSecondsUsed() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}
