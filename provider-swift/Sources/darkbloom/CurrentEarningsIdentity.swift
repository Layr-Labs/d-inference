import ProviderCoreFoundation

struct CurrentEarningsIdentity: Equatable {
    let providerKey: String?
    let machineID: String?
}

/// Resolve this Mac through the authenticated account's opaque key-to-machine
/// mapping. Missing or conflicting evidence stays unknown; do not read a raw
/// hardware serial or reuse another account's saved daemon identity.
func resolveCurrentEarningsIdentity(
    accountID: String,
    providers: [ProviderAccountEarningsReport.ProviderIdentity],
    daemonIdentity: DaemonState.Identity?
) -> CurrentEarningsIdentity {
    guard !accountID.isEmpty,
          let daemonIdentity, daemonIdentity.operatorAddress == accountID,
          let key = daemonIdentity.providerKey, !key.isEmpty
    else { return CurrentEarningsIdentity(providerKey: nil, machineID: nil) }
    let machines = Set(providers.filter { $0.providerKey == key && !$0.machineID.isEmpty }.map(\.machineID))
    return CurrentEarningsIdentity(providerKey: key, machineID: machines.count == 1 ? machines.first : nil)
}
