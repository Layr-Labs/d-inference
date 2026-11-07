import Darwin
import Foundation
import Testing

@testable import darkbloom

/// `route key`'s hidden prompt turns the terminal's echo off while the key is typed. ^C, or another signal that ends
/// the command, while it waits must give the echo back first, or the shell is left typing blind.
///
/// Signal handling is process-wide, so each case runs in a child process, on a pseudo-terminal, with a deadline: a
/// prompt that keeps waiting ends the child with SIGALRM, which fails the case instead of blocking the test run.
@Suite("route key: the hidden prompt")
struct RouteKeyHiddenPromptTests {
    @Test("^C while the key is typed gives the terminal its echo back first")
    func anInterruptGivesTheEchoBack() async {
        await #expect(processExitsWith: .success) {
            alarm(hiddenPromptDeadlineSeconds)
            let (_, terminal) = try pseudoTerminal()
            interruptOnceEchoIsOff(terminal)
            _ = RouteKeyFlow.readHidden(prompt: "key: ", terminal: terminal) { signal in
                exit(signal == SIGINT && echoes(terminal) ? EXIT_SUCCESS : 3)
            }
            exit(4)
        }
    }

    @Test("^C while the key is typed still ends the command as an interrupt")
    func anInterruptStillEndsTheCommand() async {
        await #expect(processExitsWith: .signal(SIGINT)) {
            alarm(hiddenPromptDeadlineSeconds)
            let (_, terminal) = try pseudoTerminal()
            interruptOnceEchoIsOff(terminal)
            _ = RouteKeyFlow.readHidden(prompt: "key: ", terminal: terminal)
            exit(4)
        }
    }

    @Test("a typed line comes back, and the terminal echoes again")
    func aTypedLineComesBack() async {
        await #expect(processExitsWith: .success) {
            alarm(hiddenPromptDeadlineSeconds)
            let (keyboard, terminal) = try pseudoTerminal()
            Thread.detachNewThread {
                while echoes(terminal) { usleep(1_000) }
                _ = "sk-typed\n".withCString { write(keyboard, $0, strlen($0)) }
            }
            let typed = RouteKeyFlow.readHidden(prompt: "key: ", terminal: terminal)
            #expect(typed == "sk-typed")
            #expect(echoes(terminal))
        }
    }
}

private let hiddenPromptDeadlineSeconds: UInt32 = 10

/// A pseudo-terminal in the mode a shell leaves it in (echo, lines, signals): the keyboard end and the terminal end.
/// What the prompt writes is read off the keyboard end as a screen would, so its output drains: a mode change that
/// waits for that (`TCSAFLUSH`) would otherwise wait forever.
private func pseudoTerminal() throws -> (keyboard: Int32, terminal: Int32) {
    var master: Int32 = -1
    var slave: Int32 = -1
    try #require(openpty(&master, &slave, nil, nil, nil) == 0)
    var cooked = termios()
    try #require(tcgetattr(slave, &cooked) == 0)
    cooked.c_lflag |= tcflag_t(ECHO | ICANON | ISIG)
    try #require(tcsetattr(slave, TCSANOW, &cooked) == 0)
    let screen = master
    Thread.detachNewThread {
        var shown = [UInt8](repeating: 0, count: 256)
        while read(screen, &shown, shown.count) > 0 {}
    }
    return (master, slave)
}

private func echoes(_ terminal: Int32) -> Bool {
    var mode = termios()
    return tcgetattr(terminal, &mode) == 0 && mode.c_lflag & tcflag_t(ECHO) != 0
}

/// Sends this process ^C's signal once the prompt has turned echo off and waits in its read.
private func interruptOnceEchoIsOff(_ terminal: Int32) {
    Thread.detachNewThread {
        while echoes(terminal) { usleep(1_000) }
        usleep(50_000)
        kill(getpid(), SIGINT)
    }
}
