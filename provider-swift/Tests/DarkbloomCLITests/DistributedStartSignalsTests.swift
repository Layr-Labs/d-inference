import Darwin
import Foundation
import Testing

@testable import darkbloom

/// While a distributed start runs it ignores SIGTERM and SIGINT and watches
/// them itself; closing must put back what each signal did before. Signal
/// dispositions are process-wide, so each case runs in a child process.
@Suite("Distributed start signals")
struct DistributedStartSignalsTests {
    @Test("an ignored first signal does not keep the second from being restored")
    func ignoredFirstSignalDoesNotEndTheRestore() async {
        await #expect(processExitsWith: .success) {
            install(.ignored, for: SIGTERM)
            install(.defaultAction, for: SIGINT)

            let signals = try DistributedStartSignals()
            #expect(handler(of: SIGTERM) == .ignored)
            #expect(handler(of: SIGINT) == .ignored)
            signals.close()

            #expect(handler(of: SIGTERM) == .ignored)
            #expect(handler(of: SIGINT) == .defaultAction)
        }
    }

    @Test("default and ignored signals are restored whichever comes first")
    func defaultThenIgnoredIsRestored() async {
        await #expect(processExitsWith: .success) {
            install(.defaultAction, for: SIGTERM)
            install(.ignored, for: SIGINT)

            try DistributedStartSignals().close()

            #expect(handler(of: SIGTERM) == .defaultAction)
            #expect(handler(of: SIGINT) == .ignored)
        }
    }

    @Test("a handler comes back with the flags and blocked signals it was installed with")
    func handlerKeepsItsFlagsAndMask() async {
        await #expect(processExitsWith: .success) {
            var installed = sigaction()
            installed.__sigaction_u.__sa_sigaction = { _, _, _ in }
            installed.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&installed.sa_mask)
            sigaddset(&installed.sa_mask, SIGUSR1)
            for number in [SIGTERM, SIGINT] {
                try #require(sigaction(number, &installed, nil) == 0)
            }
            let before = [disposition(of: SIGTERM), disposition(of: SIGINT)]

            try DistributedStartSignals().close()

            #expect([disposition(of: SIGTERM), disposition(of: SIGINT)] == before)
            #expect(before[0].flags == SA_SIGINFO | SA_ONSTACK)
        }
    }

    @Test("closing twice restores once and leaves a later change alone")
    func secondCloseChangesNothing() async {
        await #expect(processExitsWith: .success) {
            install(.defaultAction, for: SIGTERM)
            install(.defaultAction, for: SIGINT)
            let signals = try DistributedStartSignals()
            signals.close()
            install(.ignored, for: SIGINT)

            signals.close()

            #expect(handler(of: SIGINT) == .ignored)
        }
    }
}

/// What a signal does, read as the kernel stores it. `SIG_DFL` and `SIG_IGN`
/// are the addresses 0 and 1, not functions, so the handler is compared as a
/// number.
private struct Disposition: Equatable {
    var handlerAddress: UInt
    var flags: Int32
    var blocked: sigset_t
}

private enum Handler: Equatable {
    case defaultAction
    case ignored
    case function
}

private func disposition(of number: Int32) -> Disposition {
    var current = sigaction()
    sigaction(number, nil, &current)
    let address = withUnsafeBytes(of: current.__sigaction_u) { $0.load(as: UInt.self) }
    return Disposition(handlerAddress: address, flags: current.sa_flags, blocked: current.sa_mask)
}

private func handler(of number: Int32) -> Handler {
    switch disposition(of: number).handlerAddress {
    case 0: .defaultAction
    case 1: .ignored
    default: .function
    }
}

private func install(_ handler: Handler, for number: Int32) {
    var action = sigaction()
    action.__sigaction_u.__sa_handler = handler == .ignored ? SIG_IGN : SIG_DFL
    sigaction(number, &action, nil)
}
