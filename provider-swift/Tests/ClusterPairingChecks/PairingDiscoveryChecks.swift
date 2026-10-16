import Darwin
import Foundation
@testable import DarkbloomClusterRemote
@testable import DarkbloomClusterSecurity

/// Finding the listening Mac without a typed address (S17 discovery): the
/// datagram shapes, where probes go, which answers are dialed, who yields,
/// the responder's rate limit, and a whole ceremony started with no address.
extension PairingCheck {
    static func discoveryShapes() {
        typealias D = ClusterLinkPairingDiscovery
        let nonce = [UInt8](repeating: 7, count: 16)
        let here = D.Datagram(kind: .here, nonce: nonce, port: 47_421, address: ClusterLinkIPv4Address("169.254.10.20")!)
        let bytes = here.encoded()
        expectEqual(bytes.count, D.datagramLength, "a datagram is 30 bytes")
        expectEqual(D.Datagram.decode(bytes), here, "here round-trips")
        let probe = D.Datagram(kind: .probe, nonce: nonce, port: 0, address: ClusterLinkIPv4Address("169.254.1.2")!)
        expectEqual(D.Datagram.decode(probe.encoded()), probe, "probe round-trips")
        expect(D.Datagram.decode(Array(bytes.dropLast())) == nil, "a short datagram is ignored")
        expect(D.Datagram.decode(bytes + [0]) == nil, "a long datagram is ignored")
        var wrongMagic = bytes; wrongMagic[0] ^= 1
        expect(D.Datagram.decode(wrongMagic) == nil, "another magic is ignored")
        var wrongKind = bytes; wrongKind[7] = 9
        expect(D.Datagram.decode(wrongKind) == nil, "an unknown kind is ignored")
        var noPort = here; noPort.port = 0
        expect(D.Datagram.decode(noPort.encoded()) == nil, "a here without a port is ignored")
        var noAddress = here; noAddress.address = ClusterLinkIPv4Address(value: 0)
        expect(D.Datagram.decode(noAddress.encoded()) == nil, "a here without an address is ignored")
        expect(D.nonce() != D.nonce(), "nonces differ")

        let selfAssigned = ClusterLinkInterfaceAddress(address: ClusterLinkIPv4Address("169.254.12.34")!, netmask: 0xFFFF_0000)
        expectEqual(D.probeTarget(for: selfAssigned).dottedDecimal, "169.254.255.255", "a self-assigned bridge probes its /16 broadcast")
        let bench = ClusterLinkInterfaceAddress(address: ClusterLinkIPv4Address("10.0.0.1")!, netmask: 0xFFFF_FF00)
        expectEqual(D.probeTarget(for: bench).dottedDecimal, "10.0.0.255", "a /24 probes its broadcast")
        let loop = ClusterLinkInterfaceAddress(address: .loopback, netmask: 0xFF00_0000)
        expectEqual(D.probeTarget(for: loop), .loopback, "loopback probes the loopback address")

        expect(D.admissible(ClusterLinkIPv4Address("169.254.200.1")!, local: selfAssigned), "a listener on the link is dialed")
        expect(!D.admissible(ClusterLinkIPv4Address("169.254.12.34")!, local: selfAssigned), "not this Mac itself")
        expect(!D.admissible(ClusterLinkIPv4Address("169.254.255.255")!, local: selfAssigned), "not the broadcast address")
        expect(!D.admissible(ClusterLinkIPv4Address("192.168.1.5")!, local: selfAssigned), "not another subnet")
        expect(D.admissible(.loopback, local: loop), "loopback under the test policy")

        let a = ClusterLinkIPv4Address("169.254.3.4")!, b = ClusterLinkIPv4Address("169.254.9.9")!
        expect(D.shouldYield(local: b, other: a) && !D.shouldYield(local: a, other: b), "exactly one of two listeners yields: the higher address dials the lower")
        expect(!D.shouldYield(local: a, other: a), "equal addresses never yield")
    }

    static func loopbackSelection() -> ClusterLinkInterfaceSelection? {
        try? ClusterLinkInterfaceAdmission.select(interface: "lo0", localAddress: nil, peerAddress: nil, policy: .loopbackForTests,
                                                  inspector: ClusterLinkSystemInterfaceInspector())
    }

    static func discoveryLoopback() {
        guard let selection = loopbackSelection() else { expect(false, "lo0 selection"); return }
        let udp = port()
        expect(ClusterLinkPairingDiscovery.find(selection: selection, port: udp, seconds: 0.5).isEmpty, "nothing answers before a listener runs")
        let responder = ClusterLinkPairingDiscovery.Responder(selection: selection, udpPort: udp, tcpPort: 45_999)
        do { try responder.start() } catch { expect(false, "responder starts: \(error)"); return }
        let started = DispatchTime.now().uptimeNanoseconds
        let found = ClusterLinkPairingDiscovery.find(selection: selection, port: udp, seconds: 3)
        let took = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        expectEqual(found, [.init(address: .loopback, port: 45_999)], "the listener answers with its address and pairing port")
        expect(took < 1.5, "found well before the search window ends (\(took) s)")

        // Rate limit: a burst of 60 probes with fresh nonces gets at most 20 answers in its second.
        if let fd = try? ClusterLinkPairingDiscovery.udpSocket(interfaceIndex: selection.index, bind: .loopback, port: 0) {
            for _ in 0..<60 {
                let probe = ClusterLinkPairingDiscovery.Datagram(kind: .probe, nonce: ClusterLinkPairingDiscovery.nonce(), port: 0, address: .loopback)
                ClusterLinkPairingDiscovery.send(fd, probe, to: .loopback, port: udp)
            }
            var answers = 0
            let end = DispatchTime.now().uptimeNanoseconds + 600_000_000
            while DispatchTime.now().uptimeNanoseconds < end {
                guard ClusterLinkPairingDiscovery.waitReadable(fd, milliseconds: 50) else { continue }
                while ClusterLinkPairingDiscovery.receive(fd) != nil { answers += 1 }
            }
            Darwin.close(fd)
            expect(answers > 0 && answers <= ClusterLinkPairingDiscovery.maximumRepliesPerSecond, "at most 20 answers a second (got \(answers))")
            // Garbage gets no answer at all.
            if let junk = try? ClusterLinkPairingDiscovery.udpSocket(interfaceIndex: selection.index, bind: .loopback, port: 0) {
                Thread.sleep(forTimeInterval: 1.1) // a fresh rate window
                var target = ClusterLinkIPv4Address.loopback.socketAddress(port: udp)
                let payload = [UInt8]("DBPAIR1 not a probe at all, 30b".utf8)
                _ = payload.withUnsafeBytes { raw in withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(junk, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
                expect(!ClusterLinkPairingDiscovery.waitReadable(junk, milliseconds: 400), "a malformed probe gets no answer")
                Darwin.close(junk)
            }
        } else { expect(false, "probe socket") }

        responder.stop()
        responder.stop() // idempotent
        expect(ClusterLinkPairingDiscovery.find(selection: selection, port: udp, seconds: 0.6).isEmpty, "a stopped listener no longer answers")
    }

    /// Both Macs press l (discovery `.find`, no address): the first finds
    /// nobody and waits, the second finds it and dials; one code, both paired.
    static func discoveryCeremony() {
        let first = LinkSide("find-first"), second = LinkSide("find-second")
        let shared = port()
        let codes = NSLock()
        nonisolated(unsafe) var shown = [String]()
        nonisolated(unsafe) var progress = [String: [String]]()
        @Sendable func run(_ side: LinkSide, _ name: String, clusterID: String?) -> Result<ClusterLinkPairing.Result, ClusterPairingError> {
            var options = ClusterLinkPairing.Options(role: .listener, interface: "lo0")
            options.port = shared; options.policy = .loopbackForTests; options.lifetimeSeconds = 30
            options.discovery = .find; options.searchSeconds = 0.6
            let callbacks = ClusterLinkPairing.Callbacks(progress: { step in
                codes.withLock { progress[name, default: []].append("\(step)") }
            }, askConfirmation: { code, _, respond in
                codes.withLock { shown.append(code) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { respond(true) }
            })
            return ClusterLinkPairing.run(options: options,
                participant: TestPairing.storeBacked(side.identity, name: name, store: side.store, clusterID: clusterID),
                hooks: TestPairing.hooks, store: side.store, callbacks: callbacks)
        }
        nonisolated(unsafe) var firstResult: Result<ClusterLinkPairing.Result, ClusterPairingError> = .failure(.transport)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { firstResult = run(first, "first", clusterID: "found-pair"); done.signal() }
        Thread.sleep(forTimeInterval: 1.2)
        let secondResult = run(second, "second", clusterID: nil)
        if done.wait(timeout: .now() + 40) == .timedOut { expect(false, "the first run ended") }
        guard case .success(let f) = firstResult, case .success(let s) = secondResult else {
            expect(false, "both paired with no address typed: \(firstResult) / \(secondResult); progress \(codes.withLock { progress })"); return
        }
        let seen = codes.withLock { (shown, progress) }
        expectEqual(seen.0.count, 2, "each showed a code"); expectEqual(Set(seen.0).count, 1, "the same code")
        expectEqual(f.record.role, .listener, "the first Mac waited (listener)")
        expectEqual(s.record.role, .connector, "the second Mac found it and dialed (connector)")
        expectEqual(f.record.peerPin, ClusterPairingPin.of(identityKey: second.identity.identityPublicKey), "first pins second")
        expectEqual(s.record.peerPin, ClusterPairingPin.of(identityKey: first.identity.identityPublicKey), "second pins first")
        expectEqual(f.record.rosterSHA256, s.record.rosterSHA256, "same roster")
        expect(seen.1["first"]?.first?.hasPrefix("searching") == true && seen.1["first"]?.contains { $0.hasPrefix("listening") } == true,
               "first: searched, then listened: \(seen.1["first"] ?? [])")
        expect(seen.1["second"]?.first?.hasPrefix("searching") == true && seen.1["second"]?.contains("dialing") == true
               && seen.1["second"]?.contains { $0.hasPrefix("listening") } == false,
               "second: searched, then dialed without listening: \(seen.1["second"] ?? [])")
        let audit = (try? String(contentsOf: second.store.directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)) ?? ""
        expect(audit.contains("listener_found"), "the audit records the found listener")
        expect(!audit.contains("127.0.0.1"), "the audit holds no address")
    }
}
