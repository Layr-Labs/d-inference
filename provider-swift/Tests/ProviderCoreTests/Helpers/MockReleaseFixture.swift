/// Fixture for `GET /v1/releases/latest`. The shape mirrors what
/// `SelfUpdater` decodes (it accepts `bundle_hash`, `sha256`, or
/// `binary_hash`).
public struct MockReleaseFixture: Sendable {
    public var version: String
    public var platform: String
    public var url: String
    public var bundleHash: String
    public var binaryHash: String?
    public var metallibHash: String?

    public init(
        version: String = "0.99.0",
        platform: String = "macos-arm64",
        url: String = "https://example.test/darkbloom-bundle-macos-arm64.tar.gz",
        bundleHash: String = String(repeating: "a", count: 64),
        binaryHash: String? = nil,
        metallibHash: String? = nil
    ) {
        self.version = version
        self.platform = platform
        self.url = url
        self.bundleHash = bundleHash
        self.binaryHash = binaryHash
        self.metallibHash = metallibHash
    }
}
