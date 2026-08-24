import Foundation

final class DarkbloomCLIBundleAnchor {}

struct IsolatedLoginFiles {
    let directory: URL
    let tokenPath: URL
    let accountPath: URL

    static func make(
        prefix: String,
        token: String?,
        account: String?
    ) throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let tokenPath = directory.appendingPathComponent("auth_token")
        let accountPath = directory.appendingPathComponent("provider_account")
        if let token {
            try token.write(to: tokenPath, atomically: true, encoding: .utf8)
        }
        if let account {
            try account.write(to: accountPath, atomically: true, encoding: .utf8)
        }
        return Self(
            directory: directory,
            tokenPath: tokenPath,
            accountPath: accountPath
        )
    }
}

struct DarkbloomCLIResult {
    let status: Int32
    let output: String
}

func runDarkbloomCLI(
    arguments: [String],
    files: IsolatedLoginFiles
) throws -> DarkbloomCLIResult {
    let anchor = Bundle(for: DarkbloomCLIBundleAnchor.self).bundleURL
    let productsDirectory = anchor.pathExtension == "xctest"
        ? anchor.deletingLastPathComponent()
        : anchor

    let process = Process()
    process.executableURL = productsDirectory.appendingPathComponent("darkbloom")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = files.directory.path
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
    return DarkbloomCLIResult(
        status: process.terminationStatus,
        output: String(decoding: data, as: UTF8.self)
    )
}
