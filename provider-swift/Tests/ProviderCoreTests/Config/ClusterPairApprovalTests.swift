import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// The Swift mirror of the coordinator's canonical approval bytes. The
/// expected digests were printed by the coordinator's own code
/// (`registry.ParseNativeRuntimeCatalog` then `PolicySHA256`) for exactly the
/// entries built here, so a divergence in either encoder fails this suite.
@Suite("Cluster pair approval canonical policy")
struct ClusterPairApprovalTests {
    static func digest(_ label: String) -> String {
        SHA256.hash(data: Data(("cluster-pair-golden-" + label).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func entry(id: String, chips: [String], notAfter: String, schedule: Int, generation: UInt64,
                      changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["id": id, "model": "fixture/pair-model", "generation": generation,
            "plan_sha256": digest("plan"), "artifact_sha256": digest("artifact"),
            "native_runtime_sha256": digest("native"), "metallib_sha256": digest("metallib"),
            "resource_library_sha256": digest("resources"), "capability_sha256": digest("capability"),
            "resource_policy_sha256": digest("resource-policy"), "profile_sha256": digest("profile"),
            "schedule": schedule, "maximum_transport_frame": 131_112, "maximum_plaintext": 131_072,
            "maximum_records": 1024, "maximum_cumulative_plaintext": 16_777_216,
            "allowed_chips": chips, "not_after": notAfter]
        changes.forEach { value[$0] = $1 }
        return value
    }
    static func approval(_ object: [String: Any]) throws -> ClusterPairApproval {
        try JSONDecoder().decode(ClusterPairApproval.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func policySHA256(_ object: [String: Any]) throws -> String {
        ClusterConfigurationCodec.sha256(try Self.approval(object).canonicalPolicy())
    }

    @Test func canonicalBytesHashToTheCoordinatorsOwnDigests() throws {
        #expect(try policySHA256(Self.entry(id: "golden-utc", chips: ["Apple M4 Max"],
            notAfter: "2027-01-02T03:04:05Z", schedule: 1, generation: 3))
            == "eab6c4aafcc2e4312eb2ec25e1fa0442e84f83e435b7d0b8ce80e3604c15ed34")
        #expect(try policySHA256(Self.entry(id: "golden-fraction-offset", chips: ["Apple M4 Max", "Apple M4 Pro"],
            notAfter: "2027-01-02T03:04:05.123456789+02:00", schedule: 2, generation: UInt64.max))
            == "16ae9511c76ccfd769d6058b27dcbc6d0266c067f872812169bb4384f043f48e")
        #expect(try policySHA256(Self.entry(id: "golden-leap-day", chips: ["Apple M5"],
            notAfter: "2028-02-29T23:59:59.5-07:30", schedule: 1, generation: 1))
            == "b26dfdd464cf7d5b02f3bec4714bb02e62cb76a1e0dfbb85f07c0ececfed5ed5")
    }

    @Test func canonicalBytesAreExactlyWhatTheMemberPolicyReaderAccepts() throws {
        let approval = try Self.approval(Self.entry(id: "golden-utc", chips: ["Apple M4 Max", "Apple M4 Pro"],
            notAfter: "2027-01-02T03:04:05Z", schedule: 2, generation: 3))
        let policy = try NativePairMemberPolicy(approval.canonicalPolicy())
        #expect(policy.model == "fixture/pair-model" && policy.generation == 3 && policy.schedule == 2)
        #expect(policy.hashes.map(memberHex) == ["plan", "artifact", "native", "metallib", "resources",
            "capability", "resource-policy", "profile"].map(Self.digest))
        #expect(policy.maximumFrame == 131_112 && policy.maximumPlaintext == 131_072)
        #expect(policy.maximumRecords == 1024 && policy.maximumCumulative == 16_777_216)
        #expect(policy.chips == ["Apple M4 Max", "Apple M4 Pro"])
        #expect(policy.notAfter == 1_798_859_045_000_000_000)
    }

    @Test func instantsAreParsedExactlyOrRefused() {
        let parse = ClusterPairApproval.unixNanoseconds(rfc3339:)
        #expect(parse("1970-01-01T00:00:01Z") == 1_000_000_000)
        #expect(parse("2027-01-02T03:04:05Z") == 1_798_859_045_000_000_000)
        #expect(parse("2027-01-02T03:04:05.123456789+02:00") == 1_798_851_845_123_456_789)
        #expect(parse("2027-01-02T03:04:05.5Z") == 1_798_859_045_500_000_000)
        #expect(parse("2028-02-29T23:59:59-07:30") == parse("2028-03-01T07:29:59Z"))
        for refused in ["", "2027-01-02", "2027-01-02 03:04:05Z", "2027-01-02t03:04:05Z", "2027-01-02T03:04:05",
                        "2027-01-02T03:04:05z", "2027-02-29T00:00:00Z", "2027-13-01T00:00:00Z", "2027-00-10T00:00:00Z",
                        "2027-01-02T24:00:00Z", "2027-01-02T03:60:00Z", "2027-01-02T03:04:60Z", "2027-01-02T03:04:05.Z",
                        "2027-01-02T03:04:05.1234567890Z", "2027-01-02T03:04:05+0200", "2027-01-02T03:04:05+24:00",
                        "2027-01-02T03:04:05Z ", "1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "9999-01-01T00:00:00Z",
                        "２０２７-01-02T03:04:05Z"] {
            #expect(parse(refused) == nil, "\(refused) must be refused")
        }
    }

    @Test func entriesTheCoordinatorWouldRefuseNeverEncode() throws {
        let base: (String, Any) -> [String: Any] = { key, value in
            Self.entry(id: "bounds", chips: ["Apple M4 Max"], notAfter: "2027-01-02T03:04:05Z",
                schedule: 1, generation: 3, changes: [key: value])
        }
        let refused: [(String, Any)] = [("id", ""), ("id", String(repeating: "i", count: 129)), ("model", ""),
            ("generation", 0), ("schedule", 0), ("schedule", 3),
            ("plan_sha256", String(repeating: "0", count: 64)), ("profile_sha256", String(repeating: "A", count: 64)),
            ("metallib_sha256", "abcd"), ("maximum_plaintext", 0), ("maximum_plaintext", 16 * 1024 * 1024 + 1),
            ("maximum_transport_frame", 131_111), ("maximum_records", 0), ("maximum_records", 1_048_577),
            ("maximum_cumulative_plaintext", 0), ("maximum_cumulative_plaintext", 4 * 1024 * 1024 * 1024 + 1),
            ("allowed_chips", [String]()), ("allowed_chips", ["b", "a"]), ("allowed_chips", ["a", "a"]),
            ("allowed_chips", [""]), ("allowed_chips", (0..<17).map { "chip-\(String(format: "%02d", $0))" }),
            ("not_after", "tomorrow")]
        for (key, value) in refused {
            #expect(throws: (any Error).self, "\(key) = \(value) must be refused") {
                _ = try Self.approval(base(key, value)).canonicalPolicy()
            }
        }
        _ = try Self.approval(base("generation", 4)).canonicalPolicy()
    }
}
