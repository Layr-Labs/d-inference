import Testing
@testable import ProviderCoreFoundation

@Suite("SemanticVersion")
struct SemanticVersionTests {
    @Test(
        "accepts canonical SemVer 2",
        arguments: [
            "0.0.0",
            "1.2.3-alpha+001",
            "1.0.0-alpha.1",
            "1.0.0-0.3.7",
            "1.0.0-x.7.z.92+build.01",
            "184467440737095516160.0.1",
            "1.0.0-184467440737095516160",
        ]
    )
    func acceptsCanonical(_ raw: String) {
        #expect(SemanticVersion(raw) != nil)
    }

    @Test(
        "rejects malformed or noncanonical versions",
        arguments: [
            "",
            "v1.0.0",
            "1.0",
            "01.0.0",
            "1.01.0",
            "1.0.01",
            "1.0.0-",
            "1.0.0-alpha..1",
            "1.0.0-alpha.01",
            "1.0.0+",
            "1.0.0+build+second",
            "1.0.0-alpha_beta",
        ]
    )
    func rejectsNoncanonical(_ raw: String) {
        #expect(SemanticVersion(raw) == nil)
    }

    @Test("implements the SemVer prerelease precedence chain")
    func prereleasePrecedence() throws {
        let ordered = try [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ].map { try #require(SemanticVersion($0)) }

        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher)
            #expect(!(higher < lower))
        }
    }

    @Test("orders ASCII identifiers and unbounded numerics exactly")
    func asciiAndUnboundedOrdering() throws {
        let uppercase = try #require(SemanticVersion("1.0.0-B"))
        let lowercase = try #require(SemanticVersion("1.0.0-a"))
        #expect(uppercase < lowercase)

        let smaller = try #require(
            SemanticVersion("184467440737095516160.0.0")
        )
        let larger = try #require(
            SemanticVersion("184467440737095516161.0.0")
        )
        #expect(smaller < larger)
    }

    @Test("build metadata does not affect precedence")
    func buildMetadataIgnored() throws {
        let first = try #require(SemanticVersion("1.0.0+build.1"))
        let second = try #require(SemanticVersion("1.0.0+build.2"))
        #expect(first == second)
        #expect(!(first < second))
        #expect(!(second < first))
    }
}
