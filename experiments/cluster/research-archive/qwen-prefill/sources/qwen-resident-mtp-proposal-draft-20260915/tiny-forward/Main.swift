import Foundation
import MLX
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct MTPTinyForwardMain {
    static func main() throws {
        guard CommandLine.arguments == [CommandLine.arguments[0], "run-tiny-forward-on-gpu"] else {
            throw NSError(domain: "MTPTinyForwardCheck", code: 1)
        }
        let result = try Device.withDefaultDevice(.gpu) {
            try Stream.withNewDefaultStream(device: .gpu) {
                try MTPTinyForwardCheck.run()
            }
        }
        FileHandle.standardOutput.write(result + Data([10]))
    }
}
