import Foundation
import Testing

/// The production probe (`provider_sandbox_check_self`, run by the
/// `process-sandbox-check-fixture` helper, which only prints its own answer)
/// in a plain process and in one inside a minimal allow-everything sandbox.
@Suite("sandbox_check in a plain and a sandboxed process")
struct ProcessSandboxFixtureTests {
    private static let sandboxExec = "/usr/bin/sandbox-exec"

    private static func fixture() -> String {
        let bundle = Bundle(for: ProcessSandboxFixtureAnchor.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        return products.appendingPathComponent("process-sandbox-check-fixture").path
    }

    private static func answer(_ executable: String, _ arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(executable) exited normally")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("a plain process answers 0; one inside a minimal sandbox answers 1",
          .enabled(if: FileManager.default.isExecutableFile(atPath: sandboxExec)))
    func plainAndSandboxed() throws {
        #expect(try Self.answer(Self.fixture()) == "0")
        #expect(try Self.answer(Self.sandboxExec, ["-p", "(version 1)(allow default)", Self.fixture()]) == "1")
    }
}

private final class ProcessSandboxFixtureAnchor {}
