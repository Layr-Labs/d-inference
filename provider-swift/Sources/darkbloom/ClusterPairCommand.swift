import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// Pairs this Mac with the other Mac on the Thunderbolt link, with no SSH
    /// (PROD-PLAN S17). Run it on both Macs: one listens, the other connects
    /// to the address the first prints. Both screens then show the same six
    /// digits; type y on each Mac when they match. Each Mac then pins the
    /// other's attested Secure Enclave key, both countersign the cluster
    /// roster the coordinator registers, and both store the key of their link
    /// control channel, in owner-only files under ~/.darkbloom/cluster-pairing.
    struct Pair: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "pair",
            abstract: "Pair with the other Mac over the Thunderbolt link (Secure Enclave keys, a code on both screens, no SSH).")

        @Option(name: .customLong("connect"), help: "The other Mac's link address, as it printed it. Without it this Mac listens.")
        var connect: String?
        @Option(help: "Link interface, such as en7 or bridge0 (default: the one Thunderbolt interface with IPv4).")
        var interface: String?
        @Option(help: "RDMA device of the link, such as rdma_en7; picks the interface that carries its IPv4.")
        var device: String?
        @Option(name: .customLong("local-address"), help: "IPv4 address on the interface to use.")
        var localAddress: String?
        @Option(help: "TCP port of the pairing listener.")
        var port: Int = ClusterPairCommandLine.defaultPort
        @Option(name: .customLong("cluster-id"), help: "Cluster label to propose (listener; default: an earlier pairing's label, else one derived from both keys).")
        var clusterID: String?
        @Flag(help: "List this Mac's pairings instead of pairing.")
        var status = false
        @Option(help: "Unpair: remove the pairing with this pin (the trust anchor first, then the link key).")
        var forget: String?
        @Flag(help: "With --status: print the pairings as JSON (public values and file paths only).")
        var json = false
        @Flag(name: .customLong("loopback-for-tests"), help: .hidden) var loopback = false
        @Option(name: .customLong("lifetime-seconds"), help: .hidden) var lifetimeSeconds: Double = 600

        var request: ClusterPairCommandRequest {
            var request = ClusterPairCommandRequest()
            request.connect = connect; request.interface = interface; request.device = device
            request.localAddress = localAddress; request.port = port; request.clusterID = clusterID
            request.loopbackForTests = loopback; request.lifetimeSeconds = lifetimeSeconds
            return request
        }

        func validate() throws {
            if let problem = request.problem() { throw ValidationError(problem) }
            if let forget, !ClusterPairCommandLine.isPin(forget) { throw ValidationError("--forget takes a 64-digit lowercase pin (see --status).") }
            guard !(status && forget != nil) else { throw ValidationError("Choose at most one of --status and --forget.") }
            guard !json || status else { throw ValidationError("--json goes with --status.") }
        }

        func run() throws {
            do {
                if status { print(try ClusterPairCommandLine.status(json: json)); return }
                if let forget { print(try ClusterPairCommandLine.forget(pin: forget)); return }
                guard try ClusterPairCommandLine.pair(request) else { throw ExitCode(1) }
            } catch let failure as ClusterPairCommandLine.Failure {
                throw ValidationError(failure.description)
            }
        }
    }
}
