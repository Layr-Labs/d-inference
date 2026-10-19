import CryptoKit
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM resident worker contract", .serialized)
struct GLM5NextResidentRuntimeTests {
    private enum Failure: Error { case fence, publication, unexpectedRank }

    struct Fixture {
        let artifact: GLM5NextStageSessionTests.Artifact
        let descriptor: GLM5NextResidentDescriptor
        let identity: ClusterWorkerIdentity
        let resources: GLM5NextResidentResourceEnvelope

        init(cut: Int = 3, policy: GLM5NextExecutionPolicy = .reference) throws {
            let artifact = try GLM5NextStageSessionTests.Artifact()
            self.artifact = artifact
            let names = ["config.json", "model.safetensors.index.json"] + artifact.metadata.shards.keys.sorted()
            let files = try Dictionary(uniqueKeysWithValues: names.map { name in
                let data = try Data(contentsOf: artifact.url(name))
                return (name, GLM5NextArtifactIdentity.File(bytes: data.count, sha256: sha256(data)))
            })
            descriptor = try .init(modelID: "glm-resident-fixture", artifactIdentity: .init(
                repository: "synthetic/glm-resident", revision: String(repeating: "a", count: 40), files: files),
                artifactAggregateSHA256: String(repeating: "b", count: 64),
                configurationBytes: Data(contentsOf: artifact.url("config.json")), cut: cut,
                storage: .float32, executionPolicy: policy, profileID: "glm-resident-fixture-v1",
                maximumPromptTokens: 128, maximumChunkTokens: 16, maximumOutputTokens: 8,
                maximumContextTokens: 256)
            identity = .init(membershipEpoch: UUID(), modelID: descriptor.modelID,
                artifactSHA256: descriptor.artifactAggregateSHA256,
                configurationSHA256: files["config.json"]!.sha256,
                peers: [.init(id: "first", buildSHA256: String(repeating: "1", count: 64)),
                        .init(id: "last", buildSHA256: String(repeating: "2", count: 64))])
            resources = try Self.resources(descriptor: descriptor, inventory: artifact.metadata.inventory, rank: 0)
        }

        static func resources(descriptor: GLM5NextResidentDescriptor, inventory: GLM5NextWeightInventory,
                              rank: Int, hostBound: @escaping (Int) throws -> Int = { $0 },
                              loadCapacity: Int = 8 << 30, requestCapacity: Int = 64 << 20,
                              environmentCheck: @escaping () throws -> Void = {}) throws
            -> GLM5NextResidentResourceEnvelope {
            let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: 256,
                maximumPromptTokens: 128, maximumOutputTokens: 8, maximumChunkTokens: 16)
            let environment = String(repeating: "e", count: 64)
            let workspace = GLM5NextRequestStateBudget.WorkspaceEvidence(kind: .conservative,
                evidenceSHA256: String(repeating: "f", count: 64),
                configurationSHA256: sha256(try canonicalJSONData(inventory.configuration.textConfig)),
                inventorySHA256: GLM5NextArtifactMetadata.fingerprint(inventory),
                numericalPolicySHA256: try GLM5NextStageContract.policySHA256(descriptor.executionPolicy),
                executionEnvironmentSHA256: environment, layers: 0..<inventory.configuration.textConfig.hiddenLayers,
                scope: scope, nativeBytes: 1 << 20, hostBytes: 1 << 20)
            let document = try canonicalJSONData(workspace)
            return try .init(descriptor: descriptor, inventory: inventory, rank: rank,
                loadCapacityBytes: loadCapacity, requestCapacityBytes: requestCapacity,
                executionEnvironmentSHA256: environment, workspaceEvidence: document,
                authenticateWorkspace: { actual in
                    guard actual == document else { throw Failure.fence }
                }, requireExecutionEnvironment: { actual in
                    try environmentCheck()
                    guard actual == environment else { throw Failure.fence }
                }, hostAllocationBound: hostBound)
        }

        func resourcesForRank(_ rank: Int) throws -> GLM5NextResidentResourceEnvelope {
            try Self.resources(descriptor: descriptor, inventory: artifact.metadata.inventory, rank: rank)
        }

        func configuration(rank: Int, cut: Int? = nil, identity: ClusterWorkerIdentity? = nil,
                           deadline: UInt64? = nil) -> QwenResidentLoadConfiguration {
            .init(identity: identity ?? self.identity, modelDirectory: artifact.directory,
                rank: rank, stageCut: cut ?? descriptor.cut,
                deadlineUptimeNanoseconds: deadline ?? DispatchTime.now().uptimeNanoseconds + 60_000_000_000)
        }

        func request(deadline: UInt64? = nil, capacity: Int? = nil) -> ClusterWorkerReservation {
            .init(profileID: descriptor.profile.identifier, promptTokenIDs: [4, 5, 6, 7],
                stopTokenIDs: [], outputCount: 2, chunkSize: 2,
                deadlineUptimeNanoseconds: deadline ?? DispatchTime.now().uptimeNanoseconds + 30_000_000_000,
                capacityLimitBytes: capacity ?? resources.requestCapacityBytes,
                sampling: nil)
        }
    }

    private final class Pair {
        let fixture: Fixture
        let wire: ResidualStreamCollectiveFixture
        let first: GLM5NextResidentRuntime
        let last: GLM5NextResidentRuntime
        let leases = [QwenResidentProcessLease(), QwenResidentProcessLease()]
        let credentials: [ClusterDataPlaneCredential]

        init(environmentCheck: @escaping () throws -> Void = {}) throws {
            fixture = try .init(); wire = try .init()
            first = try .init(configuration: fixture.configuration(rank: 0), descriptor: fixture.descriptor,
                resources: Fixture.resources(descriptor: fixture.descriptor, inventory: fixture.artifact.metadata.inventory,
                    rank: 0, environmentCheck: environmentCheck), processLease: leases[0], hooks: .init())
            last = try .init(configuration: fixture.configuration(rank: 1), descriptor: fixture.descriptor,
                resources: fixture.resourcesForRank(1), processLease: leases[1], hooks: .init())
            let keys = [P256.Signing.PrivateKey(), P256.Signing.PrivateKey()]
            let epoch = fixture.identity.membershipEpoch
            credentials = try (0...1).map { rank in
                try .issue(identity: keys[rank], epoch: epoch, rank: rank,
                    peerPin: .init(identityPublicKey: keys[1-rank].publicKey.x963Representation))
            }
        }

        func establish(peerTopology: String = String(repeating: "d", count: 64)) throws {
            let topology = String(repeating: "d", count: 64)
            try wire.exchange(send: {
                try first.establishLoad(collective: wire.first, credential: credentials[0], topologySHA256: topology)
            }, receive: { [self] _ in
                try last.establishLoad(collective: wire.last, credential: credentials[1], topologySHA256: peerTopology)
            })
        }

        func load() throws {
            try establish()
            // Real verified loaders, sequential graph construction on one Mac.
            // Only completed authenticated transfers overlap in this fixture.
            try first.loadSelectedStage(); try last.loadSelectedStage()
            try wire.exchange(send: { try first.completeLoad() }, receive: { [self] _ in try last.completeLoad() })
        }

        func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws
            -> (Result<QwenResidentGenerationCompletion, Error>, Result<QwenResidentGenerationCompletion, Error>) {
            var firstResult: Result<QwenResidentGenerationCompletion, Error>?
            let second = try wire.exchange(send: {
                firstResult = Result { try first.start(requestID: id, onCommittedToken: token) }
            }, receive: { [self] _ in
                Result { try last.start(requestID: id, onCommittedToken: { _, _, _ in throw Failure.unexpectedRank }) }
            })
            return (try #require(firstResult), second)
        }

        func shutdown() throws {
            // exchange always joins the peer worker before returning. No pending
            // native operation remains on either rank when these fences run.
            try first.shutdown(peerFence: {}, check: {})
            try last.shutdown(peerFence: {}, check: {})
        }
    }

    @Test func environmentChangeAfterReservationRefusesBeforePublication() throws {
        // Only the first rank calls this checker; mutation occurs after LOAD and reserve return.
        var changed = false
        let pair = try Pair(environmentCheck: { if changed { throw Failure.fence } })
        defer { try? pair.shutdown() }
        try pair.load()
        let id = UUID()
        _ = try pair.first.reserve(requestID: id, request: pair.fixture.request())
        changed = true
        var publications = 0
        #expect(throws: (any Error).self) {
            try pair.first.start(requestID: id) { _, _, _ in publications += 1; return true }
        }
        #expect(publications == 0)
        #expect(pair.first.readiness == nil)
        #expect(throws: ProbeError.self) { try pair.leases[0].acquire() }
    }

    @Test func placementQuotesMatchBothResidentEnvelopesAtExactLimits() throws {
        let fixture = try Fixture()
        let inventory = fixture.artifact.metadata.inventory
        let resources = fixture.resources
        let report = try GLM5NextQualificationPlacement.evaluate(inventory: inventory,
            scope: resources.scope, executionPolicy: fixture.descriptor.executionPolicy,
            devices: (0...1).map { rank in
                .init(rank: rank, executionEnvironmentSHA256: resources.executionEnvironmentSHA256,
                    capacityLimitBytes: 8 << 30, availableMemoryBytes: 8 << 30,
                    allocatorAvailableBytes: 8 << 30, maximumBufferBytes: Int.max,
                    metadataAllowanceBytes: GLM5NextResidentResourceEnvelope.metadataAllowanceBytes)
            }, workspace: { _, _ in resources.workspace },
            transport: GLM5NextResidentResourceEnvelope.transportTerms,
            allocationBound: { _, bytes in bytes }, hostAllocationBound: { _, bytes in bytes })
        let candidate = try #require(report.candidates.first { $0.cut == fixture.descriptor.cut })
        for rank in candidate.ranks {
            func envelope(load: Int, request: Int) throws -> GLM5NextResidentResourceEnvelope {
                try Fixture.resources(descriptor: fixture.descriptor, inventory: inventory, rank: rank.rank,
                    loadCapacity: load, requestCapacity: request)
            }
            let exact = try envelope(load: rank.combinedPeakBytes, request: rank.request.reservedBytes)
            let quote = try exact.quote(descriptor: fixture.descriptor, maximumBufferBytes: Int.max,
                allocationBound: { $0 })
            #expect(quote.load.summary == rank.load)
            #expect(quote.request == rank.request)
            #expect(quote.peak.nativeBytes == rank.nativePeakBytes)
            #expect(quote.peak.hostBytes == rank.hostPeakBytes)
            #expect(quote.peak.reservedBytes == rank.combinedPeakBytes)
            let shortLoad = try envelope(load: rank.combinedPeakBytes - 1, request: rank.request.reservedBytes)
            #expect(throws: ProbeError.self) {
                try shortLoad.quote(descriptor: fixture.descriptor, maximumBufferBytes: Int.max,
                    allocationBound: { $0 })
            }
            #expect(throws: ProbeError.self) {
                try envelope(load: rank.combinedPeakBytes, request: rank.request.reservedBytes - 1)
            }
        }
    }

    @Test func admittedRequestsRepeatAndReleasedReservationsCannotReplay() throws {
        let pair = try Pair()
        defer { try? pair.shutdown() }
        #expect(pair.first.readiness == nil && pair.last.readiness == nil)
        try pair.load()
        #expect(pair.first.readiness?.dataPlane?.peerVerified == true)
        #expect(pair.last.readiness?.dataPlane?.peerVerified == true)
        #expect(throws: ClusterResidentRequestRefusal.self) {
            try pair.first.reserve(requestID: UUID(), request: pair.fixture.request(capacity: 1))
        }
        #expect(pair.first.readiness != nil)
        let released = UUID()
        _ = try pair.first.reserve(requestID: released, request: pair.fixture.request())
        pair.first.cancel(requestID: released)
        try pair.first.releaseReservation(requestID: released)
        #expect(pair.first.readiness != nil)
        #expect(throws: (any Error).self) {
            try pair.first.reserve(requestID: released, request: pair.fixture.request())
        }
        var prior: [Int]?
        for _ in 0..<2 {
            let id = UUID(), request = pair.fixture.request()
            let firstCharge = try pair.first.reserve(requestID: id, request: request)
            let lastCharge = try pair.last.reserve(requestID: id, request: request)
            #expect(firstCharge > 0 && lastCharge >= firstCharge)
            #expect(lastCharge <= pair.fixture.resources.requestCapacityBytes)
            #expect(pair.first.readiness == nil)
            var published: [Int] = []
            let results = try pair.start(id) { ordinal, token, committed in
                #expect(ordinal == published.count && committed == request.promptTokenIDs.count + ordinal)
                #expect(throws: ProbeError.self) { try pair.first.shutdown(peerFence: {}, check: {}) }
                published.append(token); return true
            }
            let first = try results.0.get(), last = try results.1.get()
            #expect(first.selectedTokenIDs == published && last.selectedTokenIDs == published)
            #expect(first.bothRequestStatesRetired && last.bothRequestStatesRetired)
            #expect(first.tokenChainSHA256 == last.tokenChainSHA256)
            if let prior { #expect(published == prior) }
            prior = published
            #expect(pair.first.readiness != nil && pair.last.readiness != nil)
        }
        try pair.shutdown()
        #expect(pair.first.readiness == nil && pair.last.readiness == nil)
        for lease in pair.leases { #expect(throws: ProbeError.self) { try lease.acquire() } }
    }

    @Test func failedPublicationRetainsBorrowUntilPeerFenceAndNeverReopensLease() throws {
        let pair = try Pair()
        defer { try? pair.shutdown() }
        try pair.load()
        let id = UUID(), request = pair.fixture.request()
        _ = try pair.first.reserve(requestID: id, request: request)
        _ = try pair.last.reserve(requestID: id, request: request)
        let result = try pair.start(id) { _, _, _ in throw Failure.publication }
        #expect(throws: (any Error).self) { try result.0.get() }
        #expect(throws: (any Error).self) { try result.1.get() }
        #expect(pair.first.readiness == nil && pair.last.readiness == nil)
        #expect(throws: Failure.self) {
            try pair.first.shutdown(peerFence: { throw Failure.fence }, check: {})
        }
        #expect(throws: ProbeError.self) { try pair.leases[0].acquire() }
        try pair.shutdown()
        for lease in pair.leases { #expect(throws: ProbeError.self) { try lease.acquire() } }
    }

    @Test func cancelledBeforeStartNeverPublishesAndNeedsFencedShutdown() throws {
        let pair = try Pair()
        defer { try? pair.shutdown() }
        try pair.load()
        let id = UUID()
        _ = try pair.first.reserve(requestID: id, request: pair.fixture.request())
        pair.first.cancel(requestID: id)
        var callbacks = 0
        #expect(throws: ProbeError.self) {
            try pair.first.start(requestID: id) { _, _, _ in callbacks += 1; return true }
        }
        #expect(callbacks == 0 && pair.first.readiness == nil)
        try pair.shutdown()
        #expect(throws: ProbeError.self) { try pair.leases[0].acquire() }
    }

    @Test func foreignLoadAgreementCannotReachPayloadReaderOrReadiness() throws {
        let pair = try Pair()
        defer { try? pair.shutdown() }
        #expect(throws: (any Error).self) { try pair.establish(peerTopology: String(repeating: "f", count: 64)) }
        #expect(throws: ProbeError.self) { try pair.first.loadSelectedStage() }
        #expect(throws: ProbeError.self) { try pair.last.loadSelectedStage() }
        #expect(pair.first.readiness == nil && pair.last.readiness == nil)
        try pair.shutdown()
        // No component escaped and no payload began: these isolated leases
        // can be returned only after the actual join and explicit fences.
        for lease in pair.leases { try lease.acquire(); lease.release() }
    }

    @Test func evidenceAuthenticationEnvironmentAndRankAreMandatory() throws {
        let fixture = try Fixture(), r = fixture.resources
        let document = try canonicalJSONData(r.workspace)
        var authenticated = false
        #expect(throws: Failure.self) {
            try GLM5NextResidentResourceEnvelope(descriptor: fixture.descriptor,
                inventory: fixture.artifact.metadata.inventory, rank: 0,
                loadCapacityBytes: r.loadCapacityBytes, requestCapacityBytes: r.requestCapacityBytes,
                executionEnvironmentSHA256: r.executionEnvironmentSHA256, workspaceEvidence: document,
                authenticateWorkspace: { _ in authenticated = true; throw Failure.fence },
                requireExecutionEnvironment: { _ in Issue.record("Must authenticate first") }, hostAllocationBound: { $0 })
        }
        #expect(authenticated)
        #expect(throws: ProbeError.self) {
            try GLM5NextResidentResourceEnvelope(descriptor: fixture.descriptor,
                inventory: fixture.artifact.metadata.inventory, rank: 0,
                loadCapacityBytes: r.loadCapacityBytes, requestCapacityBytes: r.requestCapacityBytes,
                executionEnvironmentSHA256: String(repeating: "a", count: 64), workspaceEvidence: document,
                authenticateWorkspace: { _ in }, requireExecutionEnvironment: { _ in }, hostAllocationBound: { $0 })
        }
        #expect(throws: ProbeError.self) {
            try GLM5NextResidentAdmission(configuration: fixture.configuration(rank: 1),
                descriptor: fixture.descriptor, resources: r, now: DispatchTime.now().uptimeNanoseconds)
        }
        let ordinary = fixture.configuration(rank: 0)
        let worker = QwenResidentLoadConfiguration(identity: ordinary.identity, modelDirectory: ordinary.modelDirectory,
            rank: ordinary.rank, stageCut: ordinary.stageCut, deadlineUptimeNanoseconds: ordinary.deadlineUptimeNanoseconds,
            allocatorPolicy: .disableFreedBufferCache)
        let a = try GLM5NextResidentAdmission(configuration: ordinary, descriptor: fixture.descriptor,
            resources: r, now: DispatchTime.now().uptimeNanoseconds)
        let b = try GLM5NextResidentAdmission(configuration: worker, descriptor: fixture.descriptor,
            resources: r, now: DispatchTime.now().uptimeNanoseconds)
        let topology = String(repeating: "d", count: 64)
        let firstAgreement = try a.loadAgreement(jacclFingerprint: topology, transport: .jaccl)
        let secondAgreement = try b.loadAgreement(jacclFingerprint: topology, transport: .jaccl)
        #expect(firstAgreement != secondAgreement)
    }

    @Test func descriptorInspectionIsMetadataOnlyAndRejectsConfigDrift() throws {
        let fixture = try Fixture()
        let inspected = try fixture.descriptor.inspectInventory(directory: fixture.artifact.directory)
        #expect(GLM5NextArtifactMetadata.fingerprint(inspected)
            == GLM5NextArtifactMetadata.fingerprint(fixture.artifact.metadata.inventory))
        // Flip only a payload byte, preserving the header and file length. A
        // metadata-only inspection still works; the SDK verifier must reject it.
        let name = try #require(fixture.artifact.metadata.shards.keys.sorted().first)
        let url = fixture.artifact.url(name)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: url)
        _ = try fixture.descriptor.inspectInventory(directory: fixture.artifact.directory)
        #expect(throws: (any Error).self) {
            try GLM5NextArtifactLoader(directory: fixture.artifact.directory,
                expectedIdentity: fixture.descriptor.artifactIdentity, storage: .float32)
        }
        var config = try Data(contentsOf: fixture.artifact.url("config.json"))
        config[config.count - 1] = 32 // Same size; differs from the pinned newline.
        try config.write(to: fixture.artifact.url("config.json"))
        #expect(throws: ProbeError.self) {
            try fixture.descriptor.inspectInventory(directory: fixture.artifact.directory)
        }
    }

    @Test func launchBindingCapacityOverflowAndExpiredRequestRefuse() throws {
        let fixture = try Fixture()
        #expect(throws: ProbeError.self) {
            try GLM5NextResidentAdmission(configuration: fixture.configuration(rank: 0, cut: 4),
                descriptor: fixture.descriptor, resources: fixture.resources, now: DispatchTime.now().uptimeNanoseconds)
        }
        #expect(throws: ProbeError.self) {
            try Fixture.resources(descriptor: fixture.descriptor, inventory: fixture.artifact.metadata.inventory,
                rank: 0, hostBound: { _ in Int.max })
        }
        let admission = try GLM5NextResidentAdmission(configuration: fixture.configuration(rank: 0),
            descriptor: fixture.descriptor, resources: fixture.resources, now: DispatchTime.now().uptimeNanoseconds)
        #expect(throws: ProbeError.self) {
            try admission.request(fixture.request(deadline: 1), id: UUID(), now: DispatchTime.now().uptimeNanoseconds)
        }
        #expect(throws: ProbeError.self) {
            try admission.request(fixture.request(capacity: 0),
                id: UUID(), now: DispatchTime.now().uptimeNanoseconds)
        }
    }

    @Test func descriptorBindsPolicyAndRejectsUnsupportedModesBeforeLoad() throws {
        let fixture = try Fixture(), d = fixture.descriptor
        func descriptor(policy: GLM5NextExecutionPolicy = .reference, mode: QwenResidentGenerationMode = .pipeline,
                        prefix: Bool = false, batch: Int = 1) throws -> GLM5NextResidentDescriptor {
            try .init(modelID: d.modelID, artifactIdentity: d.artifactIdentity,
                artifactAggregateSHA256: d.artifactAggregateSHA256,
                configurationBytes: Data(contentsOf: fixture.artifact.url("config.json")), cut: d.cut,
                storage: .float32, executionPolicy: policy, profileID: d.profile.identifier,
                maximumPromptTokens: 128, maximumChunkTokens: 16, maximumOutputTokens: 8,
                maximumContextTokens: 256, generationMode: mode, prefixReuse: prefix, batchSize: batch)
        }
        var changed = GLM5NextExecutionPolicy.reference
        changed.projections = .fusedInputs
        let foreign = try descriptor(policy: changed)
        #expect(foreign.fingerprint != d.fingerprint)
        #expect(throws: ProbeError.self) { try descriptor(mode: .pipelineMTP) }
        #expect(throws: ProbeError.self) { try descriptor(prefix: true) }
        #expect(throws: ProbeError.self) { try descriptor(batch: 2) }
    }
}
