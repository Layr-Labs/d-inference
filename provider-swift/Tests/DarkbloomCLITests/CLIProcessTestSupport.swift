import Foundation

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
