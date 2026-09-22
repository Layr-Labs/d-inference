import Foundation

public struct ConnectSnapshot: Sendable {
    public let ollama: OllamaInventory
    public let worker: WorkerIdentity?
    public let local: WorkerSnapshot?
    public let catalog: [NetworkModel]
    public let catalogAvailable: Bool
    public let evidence: ServingEvidence
    public let processVerified: Bool
    public let remoteAvailable: Bool
    public let observedAt: Date

    public static func capture() async -> Self {
        async let inventory = OllamaDiscovery.discover()
        async let catalogBytes = try? MetadataClient().get(.catalog)
        async let remoteResponse = fetchAttestations()
        let catalog = await catalogBytes.flatMap { try? CatalogPolicy.decode($0) }
        let (bytes, fetchedAt) = await remoteResponse
        let discovered = await inventory
        // The public endpoint returns an object with a providers array.
        struct Envelope: Decodable { let providers: [NetworkAttestation] }
        let remote = bytes.flatMap { try? JSONDecoder().decode(Envelope.self, from: $0).providers }
        let worker = try? WorkerIdentity.inspect()
        let local = WorkerSnapshot.read()
        let verified = local?.process_identity.map { worker?.matchesProcess($0) == true } ?? false
        let now = Date()
        let evidence = ServingEvidence.evaluate(snapshot: local, processVerified: verified,
                                               remote: remote ?? [], fetchedAt: fetchedAt, now: now.timeIntervalSince1970)
        return .init(ollama: discovered, worker: worker, local: local,
                          catalog: catalog ?? [], catalogAvailable: catalog != nil,
                          evidence: evidence, processVerified: verified, remoteAvailable: remote != nil, observedAt: now)
    }

    private static func fetchAttestations() async -> (Data?, Double) {
        let data = try? await MetadataClient().get(.attestations)
        return (data, Date().timeIntervalSince1970)
    }
}
