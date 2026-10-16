import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

/// The pairing ceremony (S17) with the provider's own pieces: the attestation
/// it signs and verifies, the roster bytes and pins of the registration (v3),
/// and the pin check a member makes before it registers a roster.
@Suite("Cluster pairing provider")
struct ClusterPairingProviderTests {
    struct SoftwareSigner: AttestationSigner {
        let key = P256.Signing.PrivateKey()
        func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
        var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
        var x963: Data { key.publicKey.x963Representation }
    }

    static func temporaryStore() -> ClusterPairingStore {
        // The real path: the installed-file checks refuse a path through a symbolic link (/var, /tmp).
        let temporary = FileManager.default.temporaryDirectory.path
        let resolved = realpath(temporary, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? temporary
        let root = URL(fileURLWithPath: resolved, isDirectory: true).appendingPathComponent("pairing-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ClusterPairingStore(directory: root.appendingPathComponent("cluster-pairing"))
    }

    /// Runs one ceremony between two provider participants in memory and stores both results.
    static func pair(_ a: SoftwareSigner, _ b: SoftwareSigner, stores: (ClusterPairingStore, ClusterPairingStore),
                     clusterID: String = "provider-pair") throws -> (ClusterPairingRecord, ClusterPairingRecord) {
        let participants: [ClusterPairingRole: ClusterPairingParticipant] = [
            .listener: ClusterPairingProvider.participant(identity: try ClusterPairingProvider.SignerIdentity(a), chipName: "Apple M3 Ultra",
                interface: "en7", store: stores.0, clusterID: clusterID),
            .connector: ClusterPairingProvider.participant(identity: try ClusterPairingProvider.SignerIdentity(b), chipName: "Apple M5 Max",
                interface: "en6", store: stores.1, clusterID: nil),
        ]
        var sessions: [ClusterPairingRole: ClusterPairingSession] = [
            .listener: try ClusterPairingSession(role: .listener, participant: participants[.listener]!, hooks: ClusterPairingProvider.hooks),
            .connector: try ClusterPairingSession(role: .connector, participant: participants[.connector]!, hooks: ClusterPairingProvider.hooks),
        ]
        var queue = [(ClusterPairingRole, Data)]()
        var completed = [ClusterPairingRole: ClusterPairingOutcome]()
        var failure: ClusterPairingError?
        func perform(_ steps: [ClusterPairingStep], _ role: ClusterPairingRole) {
            for step in steps {
                switch step {
                case .send(let message): queue.append((role == .listener ? .connector : .listener, try! message.encoded()))
                case .showCode: perform(sessions[role]!.decide(accept: true), role)
                case .persist(let outcome):
                    let store = role == .listener ? stores.0 : stores.1
                    let ok = (try? store.commit(outcome, edgeID: UUID())) != nil
                    perform(sessions[role]!.localPersisted(ok), role)
                case .completed(let outcome): completed[role] = outcome
                case .failed(let error): failure = error
                case .peerDecided, .rollback: break
                }
            }
        }
        perform(sessions[.connector]!.start(), .connector)
        while !queue.isEmpty {
            let (to, bytes) = queue.removeFirst()
            perform(sessions[to]!.receive(try ClusterPairingMessage.decode(bytes)), to)
        }
        if let failure { throw failure }
        let l = try #require(try stores.0.load()?.pairing(peerPin: ClusterMemberPin.of(uncompressedKey: b.x963)))
        let c = try #require(try stores.1.load()?.pairing(peerPin: ClusterMemberPin.of(uncompressedKey: a.x963)))
        #expect(completed.count == 2)
        return (l, c)
    }

    @Test func attestationBindsTheKeyAndTheCeremony() throws {
        let signer = SoftwareSigner(), other = SoftwareSigner()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let attestation = try AttestationBuilder(identity: signer).buildAttestationJSON(encryptionPublicKey: ephemeral.base64EncodedString())
        let posture = ClusterPairingProvider.verifyAttestation(attestation, identityKey: signer.x963, ephemeralKey: ephemeral, now: Date())
        #expect(posture != nil)
        #expect(ClusterPairingProvider.verifyAttestation(attestation, identityKey: other.x963, ephemeralKey: ephemeral, now: Date()) == nil)
        let otherEphemeral = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        #expect(ClusterPairingProvider.verifyAttestation(attestation, identityKey: signer.x963, ephemeralKey: otherEphemeral, now: Date()) == nil)
        #expect(ClusterPairingProvider.verifyAttestation(attestation, identityKey: signer.x963, ephemeralKey: ephemeral,
                                                         now: Date().addingTimeInterval(3600)) == nil)
        var tampered = attestation
        tampered[tampered.count / 2] ^= 0x01
        #expect(ClusterPairingProvider.verifyAttestation(tampered, identityKey: signer.x963, ephemeralKey: ephemeral, now: Date()) == nil)
    }

    @Test func pinsAndRosterBytesAreTheRegistrations() throws {
        let signers = [SoftwareSigner(), SoftwareSigner()]
        for signer in signers { #expect(ClusterPairingPin.of(identityKey: signer.x963) == ClusterMemberPin.of(uncompressedKey: signer.x963)) }
        let members = signers.map { (pin: ClusterPairingPin.of(identityKey: $0.x963), identityKey: $0.x963) }.sorted { $0.pin < $1.pin }
        let viaHook = try ClusterPairingProvider.hooks.rosterCanonical("roster-check", 7, members)
        let direct = try ClusterRoster.canonical(clusterID: "roster-check", generation: 7,
            keys: members.map { ($0.pin, $0.identityKey.base64EncodedString()) })
        #expect(viaHook == direct)
        #expect(ClusterPairingProvider.displayName(chipName: "Apple M3 Ultra").hasPrefix("Apple M3 Ultra, "))
        #expect(!ClusterPairingProvider.displayName(chipName: "Bad\u{1B}[2Jname").contains("\u{1B}"))
    }

    @Test func aPairedRosterRegistersAndPinsThePeer() throws {
        let a = SoftwareSigner(), b = SoftwareSigner()
        let stores = (Self.temporaryStore(), Self.temporaryStore())
        let (l, c) = try Self.pair(a, b, stores: stores)
        #expect(l.rosterSHA256 == c.rosterSHA256 && l.clusterID == "provider-pair" && c.clusterID == "provider-pair")
        #expect(l.peerPosture.sipEnabled == c.peerPosture.sipEnabled)
        let roster = ClusterPairingRosterCheck.roster(of: l)
        try roster.verify(clusterID: l.clusterID)
        #expect(roster == ClusterPairingRosterCheck.roster(of: c))
        #expect(try roster.sha256(clusterID: l.clusterID).map { String(format: "%02x", $0) }.joined() == l.rosterSHA256)
        let pins = [ClusterMemberPin.of(uncompressedKey: a.x963), ClusterMemberPin.of(uncompressedKey: b.x963)]
        try ClusterPairingRosterCheck.verify(roster: roster, localPin: pins[0], store: stores.0)
        try ClusterPairingRosterCheck.verify(roster: roster, localPin: pins[1], store: stores.1)
        // The registration both members build from it, and the data-plane pin each worker verifies.
        let profile = try ClusterRegisteredDeviceProfile(chipName: "Apple M3 Ultra", numericsClass: ClusterRosterMemberTests.classes[0],
            gpuCores: 80, memoryBytes: 256 << 30, usableWiredBytes: 200 << 30, osBuild: "25C56")
        let signers: [any AttestationSigner] = [a, b]
        for rank in 0...1 {
            let registration = try NativePairMemberRoster(clusterID: l.clusterID, rank: rank, roster: roster, rankPins: pins,
                policyBytes: try ClusterRosterMemberTests.approval().canonicalPolicy(), model: "mlx-community/Qwen3.5-9B",
                artifactSHA256: String(repeating: "02", count: 32), planSHA256: String(repeating: "ab", count: 32), cut: 16,
                mode: .pipeline, deviceProfile: profile, edges: [])
            #expect(registration.peerIdentity == (rank == 0 ? b.x963 : a.x963))
            let line = try registration.dataPlaneTrust(epoch: UUID(), rank: rank, signer: signers[rank])
            let trust = try ClusterWorkerCodec.decodeDataPlaneTrust(line)
            #expect(trust.peerPin == (rank == 0 ? b.x963 : a.x963))
        }
    }

    @Test func aRosterThisMacDidNotPairWithIsRefused() throws {
        let a = SoftwareSigner(), b = SoftwareSigner(), stranger = SoftwareSigner()
        let stores = (Self.temporaryStore(), Self.temporaryStore())
        let pinA = ClusterMemberPin.of(uncompressedKey: a.x963)
        #expect(throws: ClusterPairingRosterCheck.Refusal.notPaired) {
            try ClusterPairingRosterCheck.verify(roster: ClusterRoster(generation: 1, members: []), localPin: pinA, store: stores.0)
        }
        let (l, _) = try Self.pair(a, b, stores: stores)
        // A roster signed by a and a stranger: valid signatures, but this Mac never pinned the stranger.
        let keys = [a, stranger].map { (pin: ClusterMemberPin.of(uncompressedKey: $0.x963), sePublicKey: $0.x963.base64EncodedString()) }
            .sorted { $0.pin < $1.pin }
        let canonical = try ClusterRoster.canonical(clusterID: "provider-pair", generation: 2, keys: keys)
        let strangerRoster = ClusterRoster(generation: 2, members: try keys.map { key in
            let signer: SoftwareSigner = key.pin == pinA ? a : stranger
            return .init(pin: key.pin, sePublicKey: key.sePublicKey, signature: try ClusterRoster.signature(over: canonical, signer: signer))
        })
        try strangerRoster.verify(clusterID: "provider-pair")
        let strangerPin = ClusterMemberPin.of(uncompressedKey: stranger.x963)
        #expect(throws: ClusterPairingRosterCheck.Refusal.unpinnedMember(strangerPin)) {
            try ClusterPairingRosterCheck.verify(roster: strangerRoster, localPin: pinA, store: stores.0)
        }
        // A roster whose entry for the paired pin carries another key.
        let pinB = ClusterMemberPin.of(uncompressedKey: b.x963)
        let swapped = ClusterRoster(generation: 2, members: ClusterPairingRosterCheck.roster(of: l).members.map {
            $0.pin == pinB ? .init(pin: pinB, sePublicKey: stranger.x963.base64EncodedString(), signature: $0.signature) : $0
        })
        #expect(throws: ClusterPairingRosterCheck.Refusal.keyDiffers(pinB)) {
            try ClusterPairingRosterCheck.verify(roster: swapped, localPin: pinA, store: stores.0)
        }
        // This Mac signs with another key than the one it paired with.
        #expect(throws: ClusterPairingRosterCheck.Refusal.identityChanged) {
            try ClusterPairingRosterCheck.verify(roster: ClusterPairingRosterCheck.roster(of: l),
                localPin: ClusterMemberPin.of(uncompressedKey: stranger.x963), store: stores.0)
        }
        // A pin store whose mode was widened is not trusted.
        chmod(stores.0.recordsFile.path, 0o644)
        #expect(throws: (any Error).self) {
            try ClusterPairingRosterCheck.verify(roster: ClusterPairingRosterCheck.roster(of: l), localPin: pinA, store: stores.0)
        }
        chmod(stores.0.recordsFile.path, 0o600)
        // Unpaired: the roster no longer starts.
        _ = try stores.0.forget(peerPin: pinB)
        #expect(throws: ClusterPairingRosterCheck.Refusal.notPaired) {
            try ClusterPairingRosterCheck.verify(roster: ClusterPairingRosterCheck.roster(of: l), localPin: pinA, store: stores.0)
        }
    }

    @Test func pairCommandOptions() {
        var request = ClusterPairCommandRequest()
        #expect(request.problem() == nil)
        request.connect = "10.219.4.7"; #expect(request.problem() == nil)
        request.connect = "not-an-address"; #expect(request.problem() != nil)
        request.connect = nil; request.port = 80; #expect(request.problem() != nil)
        request.port = ClusterPairCommandLine.defaultPort; request.clusterID = "bad label"; #expect(request.problem() != nil)
        request.clusterID = "studio.pair_1"; request.lifetimeSeconds = 601; #expect(request.problem() != nil)
        request.lifetimeSeconds = 60; #expect(request.problem() == nil)
        request.listenOnly = true; #expect(request.problem() == nil)
        request.connect = "10.219.4.7"; #expect(request.problem() != nil) // --listen and --connect exclude each other
        #expect(ClusterPairCommandLine.isPin(String(repeating: "a", count: 64)))
        #expect(!ClusterPairCommandLine.isPin(String(repeating: "A", count: 64)))
    }

    /// After `darkbloom cluster pair --forget`, a saved setup's link key (the
    /// pairing's) is gone: the start names the unpairing, not a bare credential.
    @Test func aStartAfterUnpairingNamesTheUnpairing() throws {
        let stores = (Self.temporaryStore(), Self.temporaryStore())
        let (left, _) = try Self.pair(SoftwareSigner(), SoftwareSigner(), stores: stores)
        let secret = left.link.secretFile
        try DistributedInstalledValidation.linkSecretMetadata(secret)
        _ = try stores.0.forget(peerPin: left.peerPin)
        do { try DistributedInstalledValidation.linkSecretMetadata(secret); Issue.record("an unpaired link key passed") } catch {
            #expect("\(error)".contains("the Macs were unpaired"))
        }
        let other = stores.0.directory.deletingLastPathComponent().appendingPathComponent("link.secret").path
        do { try DistributedInstalledValidation.linkSecretMetadata(other); Issue.record("a missing credential passed") } catch {
            #expect(!"\(error)".contains("unpaired"))
        }
    }
}
