import CryptoKit
import Foundation
import Logging

/// GitHub is an optional transport mirror. Release discovery and every hash
/// still come from the coordinator's R2-backed release record.
struct ReleaseBundleDownloader: Sendable {
    typealias Download = @Sendable (URL) async throws -> (URL, URLResponse)

    static let githubPercentage = 10
    static let githubRequestTimeout: TimeInterval = 30
    static let githubResourceTimeout: TimeInterval = 120
    private static let logger = Logger(label: "ai.darkbloom.ReleaseBundleDownloader")
    private static let githubSession = makeGitHubSession()

    let r2Download: Download
    let githubDownload: Download
    let randomPercent: @Sendable () -> Int

    init(
        r2Session: URLSession,
        githubDownload: @escaping Download = { try await githubSession.download(from: $0) },
        randomPercent: @escaping @Sendable () -> Int = { Int.random(in: 0..<100) }
    ) {
        self.init(
            r2Download: { try await r2Session.download(from: $0) },
            githubDownload: githubDownload,
            randomPercent: randomPercent
        )
    }

    init(
        r2Download: @escaping Download,
        githubDownload: @escaping Download,
        randomPercent: @escaping @Sendable () -> Int
    ) {
        self.r2Download = r2Download
        self.githubDownload = githubDownload
        self.randomPercent = randomPercent
    }

    static func makeGitHubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = githubRequestTimeout
        configuration.timeoutIntervalForResource = githubResourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Mirror only the versioned production bundle layout emitted by CI.
    /// Never discover a version through GitHub's mutable "latest" endpoint.
    static func githubURL(release: ReleaseInfo) -> URL? {
        guard release.platform == "macos-arm64",
              let version = SemanticVersion(release.version),
              release.version == "\(version.major).\(version.minor).\(version.patch)",
              let source = URL(string: release.url),
              source.scheme == "https",
              source.path == "/releases/v\(release.version)/darkbloom-bundle-macos-arm64.tar.gz"
        else { return nil }
        return URL(string: "https://github.com/Layr-Labs/d-inference/releases/download/v\(release.version)/darkbloom-bundle-macos-arm64.tar.gz")
    }

    func download(release: ReleaseInfo, allowGitHub: Bool) async -> Result<URL, UpdateError> {
        guard let r2URL = URL(string: release.url) else {
            return .failure(.invalidURL(release.url))
        }
        do {
            try Task.checkCancellation()
            if allowGitHub, let mirror = Self.githubURL(release: release),
               randomPercent() < Self.githubPercentage {
                Self.logger.info("Release download selected GitHub", metadata: ["version": "\(release.version)"])
                do {
                    return .success(try await downloadAndVerify(
                        from: mirror, hash: release.bundleHash, using: githubDownload
                    ))
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw error
                    }
                    Self.logger.warning("GitHub release download failed; falling back to R2",
                        metadata: ["version": "\(release.version)", "error": "\(error)"])
                }
            }
            try Task.checkCancellation()
            Self.logger.info("Release download selected R2", metadata: ["version": "\(release.version)"])
            return .success(try await downloadAndVerify(
                from: r2URL, hash: release.bundleHash, using: r2Download
            ))
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    private func downloadAndVerify(
        from url: URL, hash: String, using download: Download
    ) async throws -> URL {
        let (file, response) = try await download(url)
        var verified = false
        defer {
            if !verified { try? FileManager.default.removeItem(at: file) }
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == hash.lowercased() else {
            throw UpdateError.hashMismatch(expected: hash, got: digest)
        }
        try Task.checkCancellation()
        verified = true
        return file
    }
}
