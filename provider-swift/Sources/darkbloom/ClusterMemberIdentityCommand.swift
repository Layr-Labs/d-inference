import CryptoKit
import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// The roster ceremony's two steps on one Mac, by hand until the pairing
    /// ceremony (S17) runs them over the link: print this member's pin, key
    /// and device profile v2; then countersign the roster both members agreed
    /// on. Nothing secret is printed and nothing is saved.
    struct MemberIdentity: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "member-identity",
            abstract: "Print this member's roster pin, key and device profile, or countersign a roster.", shouldDisplay: false)
        @Option(name: .customLong("metallib-sha256"), help: "The approval's metallib digest (numerics class).")
        var metallibSHA256: String?
        @Option(name: .customLong("sign-roster"), help: "Cluster label of the roster to countersign.")
        var clusterID: String?
        @Option(help: "Roster generation (with --sign-roster).") var generation: UInt64 = 1
        @Option(name: .customLong("member"), help: "PIN:BASE64-KEY of each roster member (with --sign-roster).")
        var members: [String] = []

        mutating func run() throws {
            guard let signer = ProviderLoop.clusterMemberSigner(),
                  let raw = Data(base64Encoded: signer.publicKeyBase64), raw.count == 64 else {
                throw ValidationError("This Mac has no usable Secure Enclave signing key")
            }
            let key = (Data([4]) + raw).base64EncodedString()
            let pin = ClusterMemberPin.of(uncompressedKey: Data([4]) + raw)
            if let clusterID {
                let keys = try members.map { item -> (pin: String, sePublicKey: String) in
                    let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { throw ValidationError("--member takes PIN:BASE64-KEY") }
                    return (parts[0], parts[1])
                }.sorted { $0.pin < $1.pin }
                guard keys.contains(where: { $0.pin == pin && $0.sePublicKey == key }) else {
                    throw ValidationError("This Mac's key is not a member of that roster")
                }
                let canonical = try ClusterRoster.canonical(clusterID: clusterID, generation: generation, keys: keys)
                let signature = try ClusterRoster.signature(over: canonical, signer: signer)
                try printJSON(["pin": pin, "se_public_key": key, "signature": signature,
                               "roster_sha256": Data(SHA256.hash(data: canonical)).map { String(format: "%02x", $0) }.joined()])
                return
            }
            var object: [String: String] = ["pin": pin, "se_public_key": key]
            if let metallibSHA256 {
                let hardware = try HardwareDetector.detect()
                let profile = try ClusterMemberDeviceProfile.current(chipName: hardware.chipName, gpuCores: hardware.gpuCores,
                    metallibSHA256: metallibSHA256)
                object["chip_name"] = profile.chipName; object["numerics_class"] = profile.numericsClass
                object["usable_wired_bytes"] = String(profile.usableWiredBytes); object["os_build"] = profile.osBuild
            }
            try printJSON(object)
        }
    }
}
