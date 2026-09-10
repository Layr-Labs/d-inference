import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Suite("ReleaseBundleDownloader")
struct ReleaseBundleDownloaderTests {
    private static let bytes = Data("authoritative signed bundle fixture".utf8)
    private static let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

    private func release(
        version: String = "0.9.2",
        platform: String = "macos-arm64",
        url: String? = nil,
        hash: String = Self.hash
    ) -> ReleaseInfo {
        ReleaseInfo(
            version: version, platform: platform,
            url: url ?? "https://r2.example/releases/v\(version)/darkbloom-bundle-macos-arm64.tar.gz",
            bundleHash: hash
        )
    }

    private func downloader(_ fixture: Downloads, roll: Int = 0) -> ReleaseBundleDownloader {
        ReleaseBundleDownloader(
            r2Download: { try await fixture.download($0) },
            githubDownload: { try await fixture.download($0) },
            randomPercent: { roll }
        )
    }

    @Test("Exactly ten of 100 draws select GitHub; all downloads use the authoritative hash")
    func probability() async throws {
        let fixture = try Downloads()
        defer { fixture.cleanup() }
        for roll in 0..<100 {
            let result = await downloader(fixture, roll: roll).download(
                release: release(hash: Self.hash.uppercased()), allowGitHub: true
            )
            let file = try result.get()
            #expect(try Data(contentsOf: file) == Self.bytes)
            try FileManager.default.removeItem(at: file)
        }
        let requests = await fixture.requests
        #expect(requests.count == 100)
        #expect(requests.filter { $0.host == "github.com" }.count == 10)
        #expect(requests.prefix(10).allSatisfy {
            $0.absoluteString == "https://github.com/Layr-Labs/d-inference/releases/download/v0.9.2/darkbloom-bundle-macos-arm64.tar.gz"
        })
        #expect(requests.suffix(90).allSatisfy { $0.absoluteString == release().url })
    }

    @Test("GitHub errors and corrupt bytes fall back to R2 and clean failed downloads", arguments: [
        Reply.http(404), .http(429), .http(500), .failure(.timedOut),
        .failure(.cannotFindHost), .corrupt, .unreadable,
    ])
    func fallback(reply: Reply) async throws {
        let fixture = try Downloads(github: reply)
        defer { fixture.cleanup() }
        let result = await downloader(fixture).download(release: release(), allowGitHub: true)
        let file = try result.get()
        #expect(try Data(contentsOf: file) == Self.bytes)
        #expect(await fixture.requests.map(\.host) == ["github.com", "r2.example"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == [file.lastPathComponent])
    }

    @Test("R2 remains authoritative after mirror failure", arguments: [Reply.http(503), .corrupt])
    func bothFail(r2: Reply) async throws {
        let fixture = try Downloads(github: .corrupt, r2: r2)
        defer { fixture.cleanup() }
        let result = await downloader(fixture).download(release: release(), allowGitHub: true)
        switch (r2, result) {
        case (.http, .failure(.downloadFailed(let reason))): #expect(reason == "HTTP 503")
        case (.corrupt, .failure(.hashMismatch(let expected, _))): #expect(expected == Self.hash)
        default: Issue.record("expected the R2 failure, got \(result)")
        }
        #expect(await fixture.requests.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test("Unselected failures do not try GitHub")
    func r2OnlyFailure() async throws {
        let fixture = try Downloads(r2: .http(503))
        defer { fixture.cleanup() }
        let result = await downloader(fixture, roll: 10).download(release: release(), allowGitHub: true)
        guard case .failure(.downloadFailed) = result else {
            Issue.record("expected R2 failure"); return
        }
        #expect(await fixture.requests.map(\.host) == ["r2.example"])
    }

    @Test("Cancellation never starts a fallback", arguments: [Reply.cancel, .failure(.cancelled)])
    func cancellation(reply: Reply) async throws {
        let fixture = try Downloads(github: reply)
        defer { fixture.cleanup() }
        let result = await downloader(fixture).download(release: release(), allowGitHub: true)
        guard case .failure = result else { Issue.record("expected cancellation failure"); return }
        #expect(await fixture.requests.map(\.host) == ["github.com"])
    }

    @Test("An already cancelled task does not start any download")
    func alreadyCancelled() async throws {
        let fixture = try Downloads()
        defer { fixture.cleanup() }
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await downloader(fixture).download(release: release(), allowGitHub: true)
        }.value
        guard case .failure = result else { Issue.record("expected cancellation failure"); return }
        #expect(await fixture.requests.isEmpty)
    }

    @Test("Only versioned stable macOS bundles have a mirror")
    func mirrorEligibility() {
        #expect(ReleaseBundleDownloader.githubURL(release: release()) != nil)
        for version in ["0.9.2-beta.1", "0.9.2-dev.1", "v0.9.2", "0.9.2+build", "0.9.2+../../latest", "latest"] {
            #expect(ReleaseBundleDownloader.githubURL(release: release(version: version)) == nil)
        }
        #expect(ReleaseBundleDownloader.githubURL(release: release(platform: "linux-amd64")) == nil)
        for url in [
            "https://r2.example/releases/latest/darkbloom-bundle-macos-arm64.tar.gz",
            "https://r2.example/releases/v0.9.1/darkbloom-bundle-macos-arm64.tar.gz",
            "https://r2.example/releases/v0.9.2/custom.tar.gz",
            "http://r2.example/releases/v0.9.2/darkbloom-bundle-macos-arm64.tar.gz",
        ] {
            #expect(ReleaseBundleDownloader.githubURL(release: release(url: url)) == nil)
        }
    }

    @Test("Ineligible release layouts use the exact registered URL")
    func customReleaseUsesRegisteredURL() async throws {
        let fixture = try Downloads()
        defer { fixture.cleanup() }
        let custom = release(url: "https://r2.example/custom.tar.gz?version=0.9.2")
        _ = try await downloader(fixture).download(release: custom, allowGitHub: true).get()
        #expect(await fixture.requests.map(\.absoluteString) == [custom.url])
    }

    @Test("SelfUpdater enables the mirror only for production, preserving WebSocket URL normalization",
          arguments: ["https://api.darkbloom.dev", "wss://api.darkbloom.dev/ws/provider", "https://dev.example"])
    func selfUpdaterWiring(coordinator: String) async throws {
        let fixture = try Downloads()
        defer { fixture.cleanup() }
        let updater = SelfUpdater(
            coordinatorBaseURL: coordinator, installRoot: nil,
            verifyCodeSignatures: true, currentVersion: "0.9.1",
            bundleDownloader: downloader(fixture)
        )
        _ = try await updater.downloadAndVerify(release: release()).get()
        #expect(updater.verifiesCodeSignatures)
        let expectedHost = coordinator == "https://dev.example" ? "r2.example" : "github.com"
        #expect(await fixture.requests.map(\.host) == [expectedHost])
    }

    @Test("GitHub has bounded idle and total transfer timeouts")
    func timeoutConfiguration() {
        let session = ReleaseBundleDownloader.makeGitHubSession()
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.timeoutIntervalForRequest == 30)
        #expect(session.configuration.timeoutIntervalForResource == 120)
        #expect(!session.configuration.waitsForConnectivity)
    }

    enum Reply: Sendable {
        case http(Int)
        case failure(URLError.Code)
        case corrupt
        case unreadable
        case cancel
    }

    private actor Downloads {
        nonisolated let root: URL
        var requests: [URL] = []
        let github: Reply
        let r2: Reply

        init(github: Reply = .http(200), r2: Reply = .http(200)) throws {
            self.github = github
            self.r2 = r2
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        nonisolated func cleanup() { try? FileManager.default.removeItem(at: root) }

        func download(_ url: URL) throws -> (URL, URLResponse) {
            requests.append(url)
            let reply = url.host == "github.com" ? github : r2
            let file = root.appendingPathComponent(UUID().uuidString)
            var status = 200
            switch reply {
            case .failure(let code): throw URLError(code)
            case .cancel: throw CancellationError()
            case .http(let code):
                status = code
                try ReleaseBundleDownloaderTests.bytes.write(to: file)
            case .corrupt: try Data("corrupt mirror".utf8).write(to: file)
            case .unreadable: try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            }
            return (file, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
}
