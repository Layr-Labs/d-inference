import Foundation
import Darwin

private final class ObservedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let ready = DispatchSemaphore(value: 0)
    func receive() { lock.withLock { count += 1 }; ready.signal() }
    var calls: Int { lock.withLock { count } }
}

@main enum SignalCheck {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func main() throws {
        if CommandLine.arguments.count == 2 {
            let mode = CommandLine.arguments[1]
            let scope = try DistributedStartSignals()
            let observed = ObservedSignal()
            if mode == "early" {
                kill(getpid(), SIGINT)
                Thread.sleep(forTimeInterval: 0.05)
            }
            scope.attach { observed.receive() }
            if mode == "restored" {
                scope.close(); scope.close()
                kill(getpid(), SIGTERM)
                Darwin._exit(99)
            }
            if mode == "normal" { kill(getpid(), SIGTERM) }
            try require(observed.ready.wait(timeout: .now() + 2) == .success, "termination callback missing")
            kill(getpid(), SIGINT); kill(getpid(), SIGTERM)
            Thread.sleep(forTimeInterval: 0.05)
            try require(observed.calls == 1, "termination callback repeated")
            scope.close(); scope.close()
            return
        }
        for mode in ["normal", "early", "restored"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [mode]
            try child.run(); child.waitUntilExit()
            if mode == "restored" {
                try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM,
                            "prior SIGTERM disposition was not restored")
            } else {
                try require(child.terminationReason == .exit && child.terminationStatus == 0, "signal child failed")
            }
        }
        print("3 actual-process signal checks passed")
    }
}
