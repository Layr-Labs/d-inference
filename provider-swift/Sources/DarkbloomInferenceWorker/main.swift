import Darwin
import Foundation
import InferenceWorkerCore
import InferenceWorkerProtocol

@main
struct DarkbloomInferenceWorkerMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--sandbox-self-test-v1" {
            guard ProcessInfo.processInfo.environment["DARKBLOOM_SIGNED_HOST_TEST"] == "1" else {
                _exit(EX_USAGE)
            }
            let result = WorkerSandboxSelfTest.run()
            let line = Data(
                "DBXPC_SANDBOX_SELF_TEST_V1:\(result)\n".utf8)
            line.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var written = 0
                while written < buffer.count {
                    let count = Darwin.write(
                        STDOUT_FILENO,
                        base.advanced(by: written),
                        buffer.count - written)
                    if count > 0 {
                        written += count
                    } else if errno != EINTR {
                        break
                    }
                }
            }
            _exit(result == 63 ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        guard arguments.count == 1 else { _exit(EX_USAGE) }
        do {
            try InferenceWorkerPeerIdentity.validateCurrentProcess(expected: .worker)
        } catch {
            _exit(EX_NOPERM)
        }
        let delegate = InferenceWorkerListenerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
