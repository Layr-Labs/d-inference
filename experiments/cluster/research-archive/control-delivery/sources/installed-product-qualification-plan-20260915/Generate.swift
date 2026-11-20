import Foundation
import Darwin
import DarkbloomClusterProtocol

/// CPU-only materialization. Compile with the actual MAIN configuration codec
/// sources listed by build-generator.sh. Does not call configure/store or launch
/// any process. Product binary pin is caller-supplied installation metadata.
@main enum Generate {
    static let capabilityHash = "26fa98e8d1c59f83318f806c30b81381b868818a2cb9274f49150e4b5644577e"
    static let unresolved = "/UNRESOLVED_PRODUCT_INSTALL_ROOT"

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 else {
            throw ClusterConfigurationError.invalid("Usage: generate TEMPLATE_DIRECTORY NEW_OUTPUT_DIRECTORY VERIFIED_PRODUCT_INSTALL_ROOT PROVIDER_BINARY_SHA256")
        }
        let source = URL(fileURLWithPath: args[0]), destination = URL(fileURLWithPath: args[1])
        try ClusterConfigurationFiles.requireAbsolute(args[0])
        try ClusterConfigurationFiles.requireAbsolute(args[1])
        guard ClusterConfigurationSyntax.sshPath(args[2]), !args[2].contains("UNRESOLVED"),
              args[2].hasPrefix("/Users/developer/DarkbloomDev/"),
              ClusterConfigurationSyntax.hash(args[3]), args[3] != String(repeating: "0", count: 64) else {
            throw ClusterConfigurationError.invalid("Supply a fresh absolute product installation and its actual Provider SHA-256")
        }
        var existing = stat()
        guard lstat(destination.path, &existing) != 0, errno == ENOENT else {
            throw ClusterConfigurationError.invalid("Output directory must not already exist")
        }
        let raw = try ClusterConfigurationFiles.read(source.appendingPathComponent("capability.json"), maximum: ClusterRuntimeCapabilityCodec.maximumBytes)
        guard ClusterConfigurationCodec.sha256(raw) == capabilityHash else {
            throw ClusterConfigurationError.invalid("Pinned b833 descriptor changed")
        }
        let capability = try ClusterRuntimeCapabilityCodec.decode(raw)
        var outputs: [(String, Data)] = []
        for role in ["leader", "follower"] {
            let data = try ClusterConfigurationFiles.read(source.appendingPathComponent(role + ".template.json"), maximum: ClusterConfigurationCodec.maximumBytes)
            // The real codec validates the entire closed input first; only the
            // two explicit unresolved install paths are materialized below.
            let template = try ClusterConfigurationCodec.decode(data, capability: capability, capabilitySHA256: capabilityHash)
            guard template.role.rawValue == role,
                  template.peers.allSatisfy({ $0.ownerExecutable == unresolved + "/darkbloom"
                      && $0.workerExecutable == unresolved + "/darkbloom-cluster-worker" }) else {
                throw ClusterConfigurationError.invalid("Template install placeholders or role differ")
            }
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var peers = object["peers"] as! [[String: Any]]
            for index in peers.indices {
                peers[index]["ownerExecutable"] = args[2] + "/darkbloom"
                peers[index]["workerExecutable"] = args[2] + "/darkbloom-cluster-worker"
            }
            object["peers"] = peers
            let amended = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let value = try ClusterConfigurationCodec.decode(amended, capability: capability, capabilitySHA256: capabilityHash)
            outputs.append((role + ".configure.json", try ClusterConfigurationCodec.encode(value, capability: capability, capabilitySHA256: capabilityHash)))
        }
        let binding: [String: Any] = ["schema": "installed_product_materialization_v1",
            "providerBinarySHA256": args[3], "providerPinCallerSupplied": true,
            "productInstallRoot": args[2], "capabilitySHA256": capabilityHash,
            "nativeBinarySHA256": capability.runtimeBinarySHA256,
            "installationVerified": false, "configured": false, "physicalRunExecuted": false]
        outputs.append(("product-install-binding.json", try JSONSerialization.data(withJSONObject: binding, options: [.prettyPrinted, .sortedKeys])))
        outputs.append(("capability.json", raw))
        let directory = try ClusterConfigurationFiles.directory(destination, create: true, privateMode: true)
        defer { Darwin.close(directory.descriptor) }
        for (name, bytes) in outputs {
            try ClusterConfigurationFiles.publish(bytes, parent: directory, name: name, maximum: 16 * 1024)
        }
        print("Materialized both configurations through MAIN's codec. Installation verification and cluster configure remain separate.")
    }
}
