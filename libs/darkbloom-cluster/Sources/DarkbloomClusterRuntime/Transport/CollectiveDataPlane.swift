import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// Where a resident load keys its data plane (S16): one call, after the group
/// exists and the load agreement is computed, before the first agreement
/// exchange. The same for every adapter (dense, MiMo, GPT-OSS).
enum ClusterDataPlaneAgreement {
    /// Bound into the load agreement, so a rank started without a credential
    /// and a rank started with one never agree on anything.
    static let loadAgreementFields = ["cluster-data-plane-v1", ClusterWorkerDataPlane.encrypted]

    static func establish(collective: Collective, credential: ClusterDataPlaneCredential, loadAgreement: String,
                          tamper: CollectiveRecordTamper?, rekey: ClusterRecordRekeyPolicy? = nil,
                          tensorParallelSeal: Bool = false, check: () throws -> Void) throws {
        let values = Array(loadAgreement.utf8)
        guard values.count == 64, values.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProbeError("Data-plane scope requires the canonical load agreement digest")
        }
        func digit(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
        let scope = Data(stride(from: 0, to: 64, by: 2).map { digit(values[$0]) << 4 | digit(values[$0 + 1]) })
        let started = DispatchTime.now().uptimeNanoseconds
        _ = try collective.establishDataPlane(credential: credential, scopeSHA256: scope, tamper: tamper,
            rekey: rekey ?? .dataPlane, tensorParallelSeal: tensorParallelSeal, check: check)
        log("darkbloom-data-plane-exchange-v1 rank=\(collective.rank) transport=\(collective.transportLabel)"
            + " exchange_ns=\(DispatchTime.now().uptimeNanoseconds - started)")
    }
}
