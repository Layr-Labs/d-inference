import CryptoKit
import Foundation

private enum FixtureFailure: Error { case invalid(String) }

@main enum CanonicalDescriptionCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw FixtureFailure.invalid("fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let expectedPolicy = try Data(contentsOf: root.appendingPathComponent("resource-policy.canonical.json"))
        let actualPolicy = try QwenProtectedFixturePolicy.resourcePolicyBytes()
        guard actualPolicy == expectedPolicy,
              SHA256.hash(data: actualPolicy).map({ String(format: "%02x", $0) }).joined()
                == "17cc0e02c144ef20fd4a489aa8c602069639d0005bfaf3dfea1762e46e6d5cf2" else {
            throw FixtureFailure.invalid("actual typed production policy differs from independent 17cc golden")
        }
        let expectedDescription = try Data(contentsOf: root.appendingPathComponent("description.canonical.json"))
        guard let values = try JSONSerialization.jsonObject(with: expectedDescription) as? [String: Any],
              values.count == 26 else { throw FixtureFailure.invalid("golden descriptor fields") }
        func string(_ key: String) throws -> String {
            guard let value = values[key] as? String else { throw FixtureFailure.invalid(key) }; return value
        }
        func integer(_ key: String) throws -> Int {
            guard let value = values[key] as? Int else { throw FixtureFailure.invalid(key) }; return value
        }
        func unsigned(_ key: String) throws -> UInt64 {
            guard let value = values[key] as? UInt64 else { throw FixtureFailure.invalid(key) }; return value
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = values[key] as? Bool else { throw FixtureFailure.invalid(key) }; return value
        }
        func strings(_ key: String) throws -> [String] {
            guard let value = values[key] as? [String] else { throw FixtureFailure.invalid(key) }; return value
        }
        func integers(_ key: String) throws -> [Int] {
            guard let value = values[key] as? [Int] else { throw FixtureFailure.invalid(key) }; return value
        }
        func dictionary(_ key: String) throws -> [String: String] {
            guard let value = values[key] as? [String: String] else { throw FixtureFailure.invalid(key) }; return value
        }
        let descriptor = QwenProtectedRuntimeDescriptionRecord(
            schema: try string("schema"),
            staticProfile: try string("staticProfile"),
            runtimeBinarySHA256: try string("runtimeBinarySHA256"),
            ordinaryCapabilityBase64: try string("ordinaryCapabilityBase64"),
            capabilitySHA256: try string("capabilitySHA256"),
            selectedPlanSHA256: try string("selectedPlanSHA256"),
            profileFingerprint: try string("profileFingerprint"),
            resourcePolicySHA256: try string("resourcePolicySHA256"),
            resourcePolicyBase64: try string("resourcePolicyBase64"),
            stageCut: try integer("stageCut"),
            prefillSchedule: try string("prefillSchedule"),
            promptTokens: try integer("promptTokens"),
            chunkTokens: try integer("chunkTokens"),
            outputTokens: try integer("outputTokens"),
            stopTokenIDs: try integers("stopTokenIDs"),
            maximumPlaintextBytes: try integer("maximumPlaintextBytes"),
            maximumFrameBytes: try integer("maximumFrameBytes"),
            maximumRecordsPerDirection: try unsigned("maximumRecordsPerDirection"),
            maximumCumulativePlaintextBytesPerDirection: try unsigned("maximumCumulativePlaintextBytesPerDirection"),
            bootstrapProfile: try string("bootstrapProfile"),
            sourceBindings: try dictionary("sourceBindings"),
            allocationReviews: try strings("allocationReviews"),
            experimentalExecutionOnly: try boolean("experimentalExecutionOnly"),
            wholeProcessPeakProven: try boolean("wholeProcessPeakProven"),
            rdmaMeasured: try boolean("rdmaMeasured"),
            servingEnabled: try boolean("servingEnabled"))
        var encoded = try canonicalJSONData(descriptor); encoded.append(10)
        guard encoded == expectedDescription,
              descriptor.resourcePolicyBase64 == actualPolicy.base64EncodedString(),
              descriptor.resourcePolicySHA256 == "17cc0e02c144ef20fd4a489aa8c602069639d0005bfaf3dfea1762e46e6d5cf2" else {
            throw FixtureFailure.invalid("actual typed 26-field descriptor differs from golden")
        }
        let observed = try Data(contentsOf: root.appendingPathComponent("observed-native-description.json"))
        guard let old = try JSONSerialization.jsonObject(with: observed) as? [String: Any],
              old["ordinaryCapabilityBase64"] as? String == descriptor.ordinaryCapabilityBase64,
              old["runtimeBinarySHA256"] as? String == descriptor.runtimeBinarySHA256 else {
            throw FixtureFailure.invalid("fixture no longer binds actual native3 ordinary bytes")
        }
        let ordering = ["jaccl/mesh_impl.h": "first", "jaccl/mesh.cpp": "second",
                        "source2": "two", "source10": "ten"]
        let lexical = Data(#"{"jaccl/mesh.cpp":"second","jaccl/mesh_impl.h":"first","source10":"ten","source2":"two"}"#.utf8)
        guard try canonicalJSONData(ordering) == lexical else { throw FixtureFailure.invalid("lexical ordering regression") }
        print("PASS 3 canonical description groups: actual policy17cc, 26-field native3 golden, independent lexical vector")
    }
}
