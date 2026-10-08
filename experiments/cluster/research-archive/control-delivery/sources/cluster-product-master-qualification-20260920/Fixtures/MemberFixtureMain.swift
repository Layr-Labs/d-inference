import Darwin
import Foundation

@main struct MemberFixtureMain {
    static func main() {
        signal(SIGALRM) { _ in _exit(91) }; alarm(24)
        do {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            if Array(CommandLine.arguments.dropFirst()) == ["cluster", "worker-owner", "--stdio"] {
                try memberFixtureOwner(executable: executable)
            } else if CommandLine.arguments.dropFirst().first == "--native-fixture" {
                try memberFixtureNative(executable: executable)
            } else { throw MemberFixtureError.invalid }
        } catch {
            // Closed label only: never stringify a context/key/error payload.
            try? FileHandle.standardError.write(contentsOf: Data("native-member-fixture-failed\n".utf8))
            exit(1)
        }
    }
}
