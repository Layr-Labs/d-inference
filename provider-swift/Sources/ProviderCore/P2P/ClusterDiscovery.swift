import Darwin
import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - ClusterDiscovery
//
// Auto-discovers a Thunderbolt-connected RDMA peer and establishes a
// ClusterSession (rank 0) or ClusterPeer (rank 1) without manual
// `darkbloom cluster setup`.
//
// Flow:
//   1. NWPathMonitor fires when wiredEthernet becomes available.
//   2. Own link-local IP on the Thunderbolt interface is read via getifaddrs.
//   3. Coordinator's GET /v1/cluster/rdma-peers returns the other Mac's serial
//      + SE public key (it registered with --rdma-enabled too).
//   4. Peer's Thunderbolt IP is found by parsing `arp -a -i <iface>`.
//   5. Peer SE key is pinned in the macOS Keychain (if not already there).
//   6. Rank election: lower IPv4 = rank 0. Rank 0 calls ClusterSession.start();
//      rank 1 calls ClusterPeer.serve().
//
// Hot-plug: step 1 re-fires any time the cable is connected after startup.
// Disconnect: NWPathMonitor fires again and the session is torn down.

public actor ClusterDiscovery {

    private let coordinatorURL: String
    private let authToken: String
    private let signer: any AttestationSigner

    private var pathMonitor: NWPathMonitor?
    private var sessionTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "ClusterDiscovery")

    public init(coordinatorURL: String, authToken: String, signer: any AttestationSigner) {
        self.coordinatorURL = coordinatorURL
        self.authToken = authToken
        self.signer = signer
    }

    // MARK: - Lifecycle

    /// Start watching for Thunderbolt link changes. Returns immediately; discovery
    /// runs in the background. Safe to call multiple times (idempotent).
    public func start() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        let me = self
        monitor.pathUpdateHandler = { path in
            Task { await me.handlePathChange(path) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.pathMonitor = monitor
        logger.info("ClusterDiscovery started — watching for Thunderbolt wiredEthernet")
    }

    /// Stop watching for path changes and tear down any active cluster session.
    public func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        sessionTask?.cancel()
        sessionTask = nil
        peerTask?.cancel()
        peerTask = nil
        logger.info("ClusterDiscovery stopped")
    }

    // MARK: - Path change handler

    private func handlePathChange(_ path: NWPath) async {
        if path.status == .satisfied {
            // Find the wiredEthernet interface that just became available.
            guard let iface = path.availableInterfaces.first(where: { $0.type == .wiredEthernet }) else {
                logger.warning("wiredEthernet satisfied but no interface found")
                return
            }
            logger.info("Thunderbolt wiredEthernet up on \(iface.name) — starting cluster discovery")
            await tryEstablishCluster(interface: iface.name)
        } else {
            logger.info("Thunderbolt wiredEthernet lost — tearing down cluster session")
            sessionTask?.cancel()
            sessionTask = nil
            peerTask?.cancel()
            peerTask = nil
        }
    }

    // MARK: - Discovery + connection

    private func tryEstablishCluster(interface ifName: String) async {
        // 1. Get own IP on the Thunderbolt interface.
        guard let ownIP = ownIPOnInterface(ifName) else {
            logger.warning("No IPv4 address on interface \(ifName) yet — will retry on next path update")
            return
        }
        logger.info("Own Thunderbolt IP: \(ownIP) on \(ifName)")

        // 2. Get own serial so we can exclude ourself from the RDMA peers list.
        let ownSerial = macHardwareSerialNumber() ?? ""

        // 3. Fetch RDMA-enabled peers from the coordinator.
        let rdmaPeers: [RDMAPeerInfo]
        do {
            rdmaPeers = try await ClusterCoordinatorClient.fetchRDMAPeers(
                coordinatorWSURL: coordinatorURL,
                authToken: authToken
            )
        } catch {
            logger.warning("fetchRDMAPeers failed: \(error) — cluster discovery aborted")
            return
        }

        // 4. Filter out ourself and pick the first eligible peer.
        let otherPeers = rdmaPeers.filter { $0.serial != ownSerial }
        guard let peerInfo = otherPeers.first else {
            logger.info("No RDMA-enabled peers on coordinator (own serial: \(ownSerial)) — waiting")
            return
        }
        logger.info("Found RDMA peer: serial=\(peerInfo.serial), trust=\(peerInfo.trustLevel)")

        // 5. Find peer's Thunderbolt IP from the ARP table.
        //    ARP entries may take a few seconds to populate after link-local negotiation.
        var peerIP: String?
        for attempt in 1...6 {
            peerIP = arpPeerIP(interface: ifName, excluding: ownIP)
            if peerIP != nil { break }
            logger.info("ARP table has no peer yet (attempt \(attempt)/6) — waiting 2 s")
            try? await Task.sleep(for: .seconds(2))
        }
        guard let peerIP else {
            logger.warning("No ARP neighbor on \(ifName) after retries — link-local assignment pending?")
            return
        }
        logger.info("Peer Thunderbolt IP: \(peerIP)")

        // 6. Pin peer SE key in Keychain if not already present (or if stale).
        if shouldPinSEKey(for: peerIP, expectedKey: peerInfo.sePublicKey) {
            guard let seKeyData = peerInfo.sePublicKeyData else {
                logger.warning("Peer SE key base64 decode failed for serial \(peerInfo.serial)")
                return
            }
            do {
                try ClusterPeerKeychain.store(peerSEKey: seKeyData, peerIP: peerIP)
                logger.info("SE key pinned for peer at \(peerIP)")
            } catch {
                logger.warning("Keychain pin failed: \(error)")
                return
            }
        }

        // 7. Rank election: lower IPv4 address becomes rank 0.
        let isRank0 = compareIPv4(ownIP, peerIP) == .orderedAscending
        logger.info("Rank election: own=\(ownIP) peer=\(peerIP) → \(isRank0 ? "rank 0 (initiator)" : "rank 1 (responder)")")

        if isRank0 {
            startAsRank0(peerIP: peerIP)
        } else {
            startAsRank1(peerIP: peerIP)
        }
    }

    // MARK: - Rank 0: initiate session

    private func startAsRank0(peerIP: String) {
        sessionTask?.cancel()
        let config = ClusterSessionConfig(peerIP: peerIP)
        let session = ClusterSession(config: config, signer: signer)
        sessionTask = Task {
            logger.info("Starting ClusterSession (rank 0) → \(peerIP)")
            await session.start()
        }
    }

    // MARK: - Rank 1: listen for connection

    private func startAsRank1(peerIP: String) {
        peerTask?.cancel()
        let peer = ClusterPeer(signer: signer, peerIP: peerIP)
        let log = logger
        peerTask = Task {
            log.info("Starting ClusterPeer (rank 1), expecting rank 0 from \(peerIP)")
            do {
                try await peer.serve(
                    modelState: {
                        PongPayload(modelLoaded: false, inferenceInFlight: false, memoryPressure: .normal)
                    },
                    inferenceHandler: { _, _, _ in
                        // TODO: wire up actual rank-1 inference handler
                    }
                )
            } catch {
                log.warning("ClusterPeer ended: \(error)")
            }
        }
    }

    // MARK: - SE key pinning check

    /// Returns true if we should (re-)store the SE key for `peerIP`.
    /// Avoids redundant Keychain writes when the key hasn't changed.
    private func shouldPinSEKey(for peerIP: String, expectedKey: String) -> Bool {
        guard let existing = try? ClusterPeerKeychain.load(peerIP: peerIP),
              let expected = Data(base64Encoded: expectedKey) else {
            return true  // not pinned yet
        }
        return existing != expected  // re-pin if key changed (device replaced)
    }
}

// MARK: - Network helpers (file-private, not actor-isolated)

/// Returns the first IPv4 address assigned to `ifName`, or nil if none.
private func ownIPOnInterface(_ ifName: String) -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0 else { return nil }
    defer { freeifaddrs(addrs) }

    var ptr = addrs
    while let p = ptr {
        defer { ptr = p.pointee.ifa_next }
        guard
            String(cString: p.pointee.ifa_name) == ifName,
            let addr = p.pointee.ifa_addr,
            addr.pointee.sa_family == UInt8(AF_INET)
        else { continue }

        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var s = sin.pointee.sin_addr
            var buf = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &s, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return nil
        }
    }
    return nil
}

/// Returns the first ARP neighbor on `interface` that is not `ownIP`, or nil.
/// Parses `arp -a -i <iface>` output, e.g.:
///   ? (169.254.58.74) at 12:34:56:78:9a:bc on bridge100 ifscope [ethernet]
private func arpPeerIP(interface ifName: String, excluding ownIP: String) -> String? {
    let output = runCommand("/usr/sbin/arp", ["-a", "-i", ifName])
    let ipPattern = try? NSRegularExpression(pattern: #"\((\d+\.\d+\.\d+\.\d+)\)"#)
    for line in output.components(separatedBy: "\n") where !line.isEmpty {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        if let match = ipPattern?.firstMatch(in: line, range: range),
           match.numberOfRanges > 1 {
            let ipRange = match.range(at: 1)
            let ip = nsLine.substring(with: ipRange)
            if ip != ownIP {
                return ip
            }
        }
    }
    return nil
}

/// Run a command and return its stdout as a String.
private func runCommand(_ path: String, _ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return ""
    }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Compare two dotted-decimal IPv4 strings numerically.
/// Returns `.orderedAscending` if `a` < `b`, `.orderedDescending` if `a` > `b`.
private func compareIPv4(_ a: String, _ b: String) -> ComparisonResult {
    let aOctets = a.split(separator: ".").compactMap { Int($0) }
    let bOctets = b.split(separator: ".").compactMap { Int($0) }
    for (ao, bo) in zip(aOctets, bOctets) {
        if ao < bo { return .orderedAscending }
        if ao > bo { return .orderedDescending }
    }
    return .orderedSame
}
