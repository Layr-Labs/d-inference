import Foundation
import Darwin

/// Model-free actual child: no Ready, fixed bounded diagnostic, real exit 7.
@main struct DiagnosticFailureWorker {
    static func main() throws {
        let bytes = CommandLine.arguments.dropFirst().first == "large"
            ? Data(repeating: 120, count: 1_048_577)
            : Data("fake-native: selected failure\n".utf8)
        try FileHandle.standardError.write(contentsOf: bytes)
        Darwin.exit(7)
    }
}
