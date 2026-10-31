import Darwin
import Foundation

/// A real child of the fixed local-owner launcher. No model or owner protocol.
@main enum InstalledOwnerEnvironmentProbe {
    static func main() throws {
        guard Array(CommandLine.arguments.dropFirst()) == ["cluster", "worker-owner", "--stdio"] else { exit(64) }
        let bytes = try JSONSerialization.data(withJSONObject: ProcessInfo.processInfo.environment,
            options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}
