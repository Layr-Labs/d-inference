import Foundation
import Darwin
import MLX
import DarkbloomClusterProcess
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct CollectiveAllocationMain {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["check-arguments"] || arguments == ["list-cases"]
                || (arguments.count == 2 && arguments[0] == "run-resource-case") else {
            throw NSError(domain: "CollectiveAllocationCheck.arguments", code: 1)
        }
        alarm(60)
        if arguments == ["check-arguments"] {
            FileHandle.standardOutput.write(Data("{\"argumentsAccepted\":true,\"nativeExecuted\":false}\n".utf8))
            alarm(0); return
        }
        if arguments == ["list-cases"] {
            let value = try CollectiveAllocationProbe.cases()
            guard value.count <= 65_536 else { throw NSError(domain: "CollectiveAllocationCheck.cases", code: 1) }
            FileHandle.standardOutput.write(value + Data([10])); alarm(0); return
        }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".darkbloom/cluster-device")
        let gate = try ClusterDeviceExclusion(directoryURL: directory)
        try withExtendedLifetime(gate) {
            let result = try Device.withDefaultDevice(.gpu) {
                try Stream.withNewDefaultStream(device: .gpu) {
                    try MLX.withError { native in
                        do {
                            let result = try CollectiveAllocationProbe.run(caseID: arguments[1])
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try native.check()
                            Memory.clearCache(); try native.check(); return result
                        } catch {
                            let primary = error
                            Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try native.check()
                            throw primary
                        }
                    }
                }
            }
            guard result.count <= 65_536 else { throw NSError(domain: "CollectiveAllocationCheck.output", code: 1) }
            FileHandle.standardOutput.write(result + Data([10]))
        }
        alarm(0)
    }
}
