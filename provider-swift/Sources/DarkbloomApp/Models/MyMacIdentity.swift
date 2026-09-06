import Foundation

/// The account fleet endpoint has already reconciled physical machines. Its
/// public ID is opaque: never reconstruct it from hardware or attestation keys.
struct MyMacIdentity: Hashable, Identifiable, Sendable {
    let value: String

    var id: String { "provider-id:\(value)" }

    static func resolve(providerID: String) -> MyMacIdentity? {
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return MyMacIdentity(value: providerID)
    }
}
