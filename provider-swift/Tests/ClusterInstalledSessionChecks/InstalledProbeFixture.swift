import Foundation
import Darwin
import CryptoKit

@main enum InstalledProbeFixture {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 1 {
            switch args[0] {
            case "--fixture-overflow": try FileHandle.standardOutput.write(contentsOf: Data(repeating: 32, count: 16385))
            case "--fixture-stderr": try FileHandle.standardError.write(contentsOf: Data("synthetic refusal\n".utf8))
            case "--fixture-exit": exit(7)
            case "--fixture-hang": signal(SIGTERM, SIG_IGN); while true { pause() }
            default: exit(64)
            }; return
        }
        guard args.count == 7, args[0] == "--describe-runtime", args[1] == "--config", args[3] == "--manifest",
              args[5] == "--expected-executable-sha256" else { exit(64) }
        let executable = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))
        guard SHA256.hash(data: executable).map({ String(format: "%02x", $0) }).joined() == args[6] else { exit(65) }
        // This is explicitly fabricated CPU metadata, never the native producer.
        let path = URL(fileURLWithPath: args[2]).deletingLastPathComponent().appendingPathComponent("fixture-capability.json")
        try FileHandle.standardOutput.write(contentsOf: Data(contentsOf: path))
    }
}
