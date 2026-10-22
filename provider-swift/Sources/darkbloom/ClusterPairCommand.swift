import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// Pairs this Mac with the other Mac on the Thunderbolt link, with no SSH
    /// (PROD-PLAN S17). Run it on both Macs: each looks for the other on the
    /// cable; the first waits and the second finds it and dials (no address
    /// to type; `--connect` remains for a link where probes do not pass).
    /// Both screens then show the same six
    /// digits; type y on each Mac when they match. Each Mac then pins the
    /// other's attested Secure Enclave key, both countersign the cluster
    /// roster the coordinator registers, and both store the key of their link
    /// control channel, in owner-only files under ~/.darkbloom/cluster-pairing.
    struct Pair: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "pair",
            abstract: "Pair with the other Mac over the Thunderbolt link (Secure Enclave keys, a code on both screens, no SSH).", shouldDisplay: false)

        @Option(name: .customLong("connect"), help: "The other Mac's link address, as it printed it. Without it this Mac finds the other Mac on the cable, or waits for it.")
        var connect: String?
        @Flag(help: "Only wait for the other Mac (it finds this one); do not look for it first.")
        var listen = false
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
            request.loopbackForTests = loopback; request.lifetimeSeconds = lifetimeSeconds; request.listenOnly = listen
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
                if let forget {
                    // The leader tells its member first, while the pairing still keys the link:
                    // the member reclaims the pair's prefix-tier records (its single-Mac cache stays).
                    if let line = ClusterService.tellMemberOfUnpair(peerPin: forget) { print(line) }
                    print(try ClusterPairCommandLine.forget(pin: forget))
                    // Unpaired: this Mac's cluster service has nobody to answer, so it no
                    // longer starts at login (`darkbloom cluster` pairs and installs it again).
                    if ClusterService.holdsNoPairing() {
                        do {
                            if !(try ClusterService.removeFromLogin(executable: URL(fileURLWithPath: Start.currentExecutablePath()))).isEmpty {
                                print("This Mac's cluster service is stopped and no longer starts at login.")
                            }
                        } catch { printError("note: this Mac's cluster service could not be removed from login: \(error)") }
                    }
                    // No rank of this Mac will open the pair's prefix records
                    // again: reclaim them here (the peer reclaims its own when
                    // it unpairs; a live rank's plan is left alone).
                    if let settings = try? ClusterPrefixCacheSettings.resolved(providerConfiguration: ConfigManager.defaultConfigPath()) {
                        let report = ClusterPrefixSSDReclaim.reclaim(root: settings.root)
                        if report.removedPlans > 0 || report.keptLive > 0 || !report.problems.isEmpty {
                            print("Cluster prefix tier: removed \(report.removedPlans) plan\(report.removedPlans == 1 ? "" : "s")"
                                + (report.keptLive > 0 ? ", \(report.keptLive) in use by a running rank (kept)" : "")
                                + (report.problems.isEmpty ? "" : "; " + report.problems.joined(separator: "; ")) + ".")
                        }
                    }
                    return
                }
                guard try ClusterPairCommandLine.pair(request) else { throw ExitCode(1) }
            } catch let failure as ClusterPairCommandLine.Failure {
                throw ValidationError(failure.description)
            }
        }
    }
}
