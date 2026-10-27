import Foundation
import Darwin
import MLX
import DarkbloomClusterProcess
@_spi(ClusterTesting) import DarkbloomClusterRuntime

/// Private qualification entry. It never loads checkpoint weights or launches peers.
@main struct WindowedRequestStateMain {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["run-windowed-state-on-gpu"] || arguments == ["check-arguments"] else {
            throw NSError(domain: "WindowedRequestStateCheck.arguments", code: 1)
        }
        // Keep the process bound through final stdout publication as well as native work.
        alarm(60)
        if arguments == ["check-arguments"] {
            FileHandle.standardOutput.write(Data("{\"argumentsAccepted\":true,\"nativeExecuted\":false}\n".utf8))
            alarm(0)
            return
        }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".darkbloom/cluster-device")
        let gate = try ClusterDeviceExclusion(directoryURL: directory)
        try withExtendedLifetime(gate) {
            let result = try Device.withDefaultDevice(.gpu) {
                try Stream.withNewDefaultStream(device: .gpu) {
                    try MLX.withError { native in
                        do {
                            let result = try WindowedRequestStateCheck.run()
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try native.check()
                            Memory.clearCache(); try native.check()
                            return result
                        } catch {
                            Stream.gpu.synchronize(); Stream.cpu.synchronize()
                            try native.check()
                            Memory.clearCache(); try native.check()
                            throw error
                        }
                    }
                }
            }
            guard result.count <= 16_384 else { throw NSError(domain: "WindowedRequestStateCheck.output", code: 1) }
            FileHandle.standardOutput.write(result + Data([10]))
        }
        alarm(0)
    }
}
