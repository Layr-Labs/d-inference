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

    /// Optional model directory. When set before or during jaccl bootstrap,
    /// `ClusterDiscovery` will automatically construct `TensorParallelEngine`
    /// (rank 0) or `TensorParallelServer` (rank 1) and expose them via
    /// `currentEngine()` / `currentServer()`. PR 4d sets this from the provider
    /// loop after the model is loaded; if nil, construction is skipped.
    public private(set) var modelDirectory: URL?

    private var pathMonitor: NWPathMonitor?
    private var sessionTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?

    /// The initialized jaccl DistributedGroup. Available after the jaccl
    /// bootstrap step completes on either rank. Nil until then.
    ///
    /// Subsequent PRs (4b+) read this via `distributedGroup` to access the
    /// group for TP inference allreduces.
    private var _distributedGroup: DistributedGroup?

    // MARK: - TP engine/server (set after jaccl bootstrap + model load)

    /// Rank 0 engine. Set after jaccl bootstrap completes and LlamaModelTP is loaded.
    /// PR 4d calls `currentEngine()` to dispatch consumer requests through this.
    private var _engine: TensorParallelEngine?

    /// Rank 1 server. Set after jaccl bootstrap completes and LlamaModelTP is loaded.
    private var _server: TensorParallelServer?

    /// Held for the running rank (for diagnostics only; actual session ref lives
    /// inside _engine / _server).
    private var _activeSession: ClusterSession?
    private var _activePeer: ClusterPeer?

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
        _distributedGroup = nil
        _engine = nil
        _server = nil
        _activeSession = nil
        _activePeer = nil
        logger.info("ClusterDiscovery stopped")
    }

    /// Set the model directory so ClusterDiscovery can construct the TP engine/server
    /// after jaccl bootstrap completes. Call this from the provider loop once the
    /// active model is loaded. Idempotent — re-setting with the same path is a no-op.
    public func setModelDirectory(_ url: URL) {
        guard url != modelDirectory else { return }
        modelDirectory = url
        logger.info("ClusterDiscovery: model directory set to \(url.path)")
    }

    /// The initialized jaccl `DistributedGroup`. Nil until after a successful
    /// `jacclBootstrap` exchange on both ranks. Check this before kicking off
    /// TP inference; if nil, fall back to PP or single-rank.
    public var distributedGroup: DistributedGroup? { _distributedGroup }

    /// The rank-0 `TensorParallelEngine` for this cluster session. Non-nil on rank 0
    /// after jaccl bootstrap completes and `LlamaModelTP` is loaded. Nil on rank 1.
    /// PR 4d dispatches consumer requests through this.
    public func currentEngine() -> TensorParallelEngine? { _engine }

    /// The rank-1 `TensorParallelServer` for this cluster session. Non-nil on rank 1
    /// after jaccl bootstrap completes and `LlamaModelTP` is loaded. Nil on rank 0.
    public func currentServer() -> TensorParallelServer? { _server }

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
            startAsRank0(ownIP: ownIP, peerIP: peerIP)
        } else {
            startAsRank1(ownIP: ownIP, peerIP: peerIP)
        }
    }

    // MARK: - Rank 0: initiate session

    private func startAsRank0(ownIP: String, peerIP: String) {
        sessionTask?.cancel()
        let config = ClusterSessionConfig(peerIP: peerIP)
        let session = ClusterSession(config: config, signer: signer)
        _activeSession = session
        let log = logger
        let me = self
        sessionTask = Task {
            log.info("Starting ClusterSession (rank 0) → \(peerIP)")
            // Run the session connect loop in a child task so we can observe
            // when the session becomes ready and trigger jaccl bootstrap without
            // waiting for the infinite reconnect loop to exit.
            async let _ = session.start()

            // Poll until the session health becomes non-unavailable, meaning the
            // SE handshake completed and a connection is established.
            // Bounded at 60 s (120 × 500 ms) — beyond that something is broken.
            var attempts = 0
            while attempts < 120 {
                let h = await session.health
                if case .unavailable = h {
                    try? await Task.sleep(for: .milliseconds(500))
                    attempts += 1
                } else {
                    break
                }
            }
            // If still unavailable after polling, abort.
            if case .unavailable = await session.health {
                log.warning("Session never became ready after 60 s — jaccl bootstrap skipped")
                return
            }

            // SE handshake completed. Now bootstrap jaccl on rank 0.
            //
            // 1. Generate a unique session ID and pick the jaccl coordinator port.
            let sessionID = UUID().uuidString
            let jacclPort: UInt16 = 29400

            // 2. Send jacclBootstrap frame to rank 1 via the control channel.
            let bootstrapPayload = JacclBootstrapPayload(port: jacclPort, sessionID: sessionID)
            do {
                let conn = try await session.connection()
                let frame = try ClusterFrame.encodeJSON(type: .jacclBootstrap, value: bootstrapPayload)
                try await conn.send(frame)
                log.info("Sent jacclBootstrap to rank 1: port=\(jacclPort), session=\(sessionID)")
            } catch {
                log.warning("Failed to send jacclBootstrap frame: \(error) — jaccl not initialized")
                return
            }

            // 3. Initialize jaccl DistributedGroup as rank 0.
            let bootstrapConfig = DistributedGroupBootstrapConfig(
                ownRank: 0,
                ownIP: ownIP,
                peerIP: peerIP,
                port: jacclPort,
                sessionID: sessionID
            )
            do {
                let group = try DistributedGroupBootstrap.bootstrap(bootstrapConfig)
                await me.setDistributedGroup(group)
                log.info("jaccl DistributedGroup ready (rank 0): size=\(group.size)")

                // 4. Construct TensorParallelEngine if a model directory is available.
                //    We do this here (instead of in setModelDirectory) so either ordering
                //    works: model loaded before jaccl, or jaccl ready before model.
                await me.tryBuildRank0Engine(session: session)
            } catch {
                log.warning("jaccl bootstrap failed (rank 0): \(error)")
            }
        }
    }

    /// Build `TensorParallelEngine` on rank 0 once both the jaccl group (env vars set
    /// by bootstrap) and the model directory are available. Safe to call multiple times —
    /// bails early if either dependency is missing or the engine is already built.
    private func tryBuildRank0Engine(session: ClusterSession) {
        guard _engine == nil else { return }
        guard let modelDir = modelDirectory else {
            logger.info("TP engine deferred: modelDirectory not yet set (will build when set)")
            return
        }
        do {
            // ClusterModelLoader reads the jaccl group from the process environment
            // (set by DistributedGroupBootstrap.setEnvironmentVariables during bootstrap).
            let model = try ClusterModelLoader.load(modelDirectory: modelDir)
            let tpConfig = TensorParallelConfig(
                numLayers: model.kvHeads.count,
                hiddenDim: 0,  // informational only; not used in the decode loop
                vocabSize: model.vocabularySize,
                worldSize: model.group.size)
            // Construct a stub tokenizer — engine.generate takes raw token IDs so
            // the tokenizer is only needed for chat-template formatting (PR 4d).
            let tokenizer = StubTokenizer()
            // Box model in an @unchecked Sendable wrapper so Swift 6 accepts the
            // actor boundary crossing. LlamaModelTP is constructed here, owned by
            // the TensorParallelEngine actor from this point forward.
            let sendableModel = UncheckedSendableLLMModel(value: model)
            let engine = TensorParallelEngine(
                config: tpConfig,
                model: sendableModel,
                tokenizer: tokenizer,
                session: session)
            setEngine(engine)
            logger.info("TensorParallelEngine constructed (rank 0): vocab=\(model.vocabularySize)")
        } catch {
            logger.warning("Failed to build TensorParallelEngine: \(error)")
        }
    }

    // MARK: - Rank 1: listen for connection

    private func startAsRank1(ownIP: String, peerIP: String) {
        peerTask?.cancel()
        let peer = ClusterPeer(signer: signer, peerIP: peerIP)
        _activePeer = peer
        let log = logger
        let me = self
        peerTask = Task {
            log.info("Starting ClusterPeer (rank 1), expecting rank 0 from \(peerIP)")
            do {
                // Build a mutable holder for the TensorParallelServer handler so we can
                // wire it in once the server is constructed after jaccl bootstrap.
                // `inferenceHandler` is captured by reference via an actor-isolated
                // server instance.
                try await peer.serve(
                    modelState: {
                        PongPayload(modelLoaded: false, inferenceInFlight: false, memoryPressure: .normal)
                    },
                    inferenceHandler: { _, _, frame in
                        // Route to TensorParallelServer if it's been constructed.
                        // If not yet constructed (bootstrap in progress), drop the frame
                        // with a warning — rank 0 won't send inference frames before
                        // bootstrap completes in normal operation.
                        let server = await me.currentServer()
                        guard let server else {
                            log.warning("Rank 1: inference frame received before TensorParallelServer is ready — dropping")
                            return
                        }
                        // Route frame to actor-isolated handleFrame method.
                        // Rank 1 never sends back in TP; conn/key are not needed.
                        try await server.handleFrame(frame)
                    },
                    bootstrapHandler: { _, _, frame in
                        // Dedicated handler for the jacclBootstrap frame — cleanly
                        // separated from inference frames (PR 4a used inferenceHandler
                        // as a stopgap; this dedicated path is correct).
                        let payload = try ClusterFrame.decodeJSON(JacclBootstrapPayload.self, from: frame)
                        log.info("Rank 1 received jacclBootstrap: port=\(payload.port), session=\(payload.sessionID)")

                        // Initialize jaccl DistributedGroup as rank 1.
                        let bootstrapConfig = DistributedGroupBootstrapConfig(
                            ownRank: 1,
                            ownIP: ownIP,
                            peerIP: peerIP,
                            port: payload.port,
                            sessionID: payload.sessionID
                        )
                        do {
                            let group = try DistributedGroupBootstrap.bootstrap(bootstrapConfig)
                            await me.setDistributedGroup(group)
                            log.info("jaccl DistributedGroup ready (rank 1): size=\(group.size)")

                            // Construct TensorParallelServer if model directory is set.
                            await me.tryBuildRank1Server()
                        } catch {
                            log.warning("jaccl bootstrap failed (rank 1): \(error)")
                        }
                    }
                )
            } catch {
                log.warning("ClusterPeer ended: \(error)")
            }
        }
    }

    /// Build `TensorParallelServer` on rank 1 once both the jaccl group (env vars set
    /// by bootstrap) and the model directory are available.
    private func tryBuildRank1Server() {
        guard _server == nil else { return }
        guard let modelDir = modelDirectory else {
            logger.info("TP server deferred: modelDirectory not yet set (will build when set)")
            return
        }
        do {
            let model = try ClusterModelLoader.load(modelDirectory: modelDir)
            let tpConfig = TensorParallelConfig(
                numLayers: model.kvHeads.count,
                hiddenDim: 0,
                vocabSize: model.vocabularySize,
                worldSize: model.group.size)
            let sendableModel = UncheckedSendableLLMModel(value: model)
            let server = TensorParallelServer(config: tpConfig, model: sendableModel)
            setServer(server)
            logger.info("TensorParallelServer constructed (rank 1): vocab=\(model.vocabularySize)")
        } catch {
            logger.warning("Failed to build TensorParallelServer: \(error)")
        }
    }

    /// Actor-isolated setter for the distributed group.
    /// Called from within Task closures after jaccl initializes.
    private func setDistributedGroup(_ group: DistributedGroup) {
        _distributedGroup = group
    }

    /// Actor-isolated setters for engine/server. Called after model load completes.
    private func setEngine(_ engine: TensorParallelEngine) {
        _engine = engine
    }

    private func setServer(_ server: TensorParallelServer) {
        _server = server
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
