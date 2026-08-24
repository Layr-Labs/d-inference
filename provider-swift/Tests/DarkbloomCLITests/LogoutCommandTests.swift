import Foundation
import Testing

private final class LogoutBundleAnchor {}

@Suite("Logout clears every login-state artifact")
struct LogoutCommandTests {
    private struct LoginFiles {
        let dir: URL
        let tokenPath: URL
        let accountPath: URL
    }

    private var binary: URL {
        let anchor = Bundle(for: LogoutBundleAnchor.self).bundleURL
        let productsDir = anchor.pathExtension == "xctest"
            ? anchor.deletingLastPathComponent()
            : anchor
        return productsDir.appendingPathComponent("darkbloom")
    }

    private func loginFiles(
        token: String?, account: String?
    ) throws -> LoginFiles {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logout-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tokenPath = dir.appendingPathComponent("auth_token")
        let accountPath = dir.appendingPathComponent("provider_account")
        if let token {
            try token.write(to: tokenPath, atomically: true, encoding: .utf8)
        }
        if let account {
            try account.write(to: accountPath, atomically: true, encoding: .utf8)
        }
        return LoginFiles(dir: dir, tokenPath: tokenPath, accountPath: accountPath)
    }

    private func runLogout(with files: LoginFiles) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["logout"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = files.dir.path
        environment["DARKBLOOM_AUTH_TOKEN_PATH"] = files.tokenPath.path
        environment["DARKBLOOM_PROVIDER_ACCOUNT_PATH"] = files.accountPath.path
        environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("logout removes the account id alongside the token")
    func clearsAccountID() throws {
        let files = try loginFiles(token: "tok-123", account: "acct-456")
        defer { try? FileManager.default.removeItem(at: files.dir) }

        let output = try runLogout(with: files)

        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path),
            "a stale account id would keep `earnings`/daemon-state identity pointing at the previous account")
        #expect(!FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(output.contains("Logged out."))
    }

    @Test("logout succeeds when only the account id exists (partial state)")
    func clearsAccountWithoutToken() throws {
        let files = try loginFiles(token: nil, account: "acct-456")
        defer { try? FileManager.default.removeItem(at: files.dir) }

        let output = try runLogout(with: files)

        #expect(!FileManager.default.fileExists(atPath: files.accountPath.path))
        #expect(!FileManager.default.fileExists(atPath: files.tokenPath.path))
        #expect(output.contains("Logged out."))
    }
}
