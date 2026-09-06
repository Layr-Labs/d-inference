import ProviderCoreFoundation
import Testing
@testable import darkbloom

@Test("Current earnings identity requires account-bound, unambiguous server mapping")
func currentEarningsIdentityUsesOpaqueMapping() {
    let daemon = DaemonState.Identity(providerName: "Mac", operatorAddress: "account", providerKey: "key")
    let mapping = ProviderAccountEarningsReport.ProviderIdentity(
        providerID: "opaque-session", providerKey: "key", machineID: "opaque-machine"
    )
    let result = resolveCurrentEarningsIdentity(accountID: "account", providers: [mapping], daemonIdentity: daemon)
    #expect(result.providerKey == "key")
    #expect(result.machineID == "opaque-machine")
    #expect(resolveCurrentEarningsIdentity(
        accountID: "other-account", providers: [mapping], daemonIdentity: daemon
    ) == CurrentEarningsIdentity(providerKey: nil, machineID: nil))
    #expect(resolveCurrentEarningsIdentity(
        accountID: "account", providers: [], daemonIdentity: daemon
    ).machineID == nil)
    let conflict = ProviderAccountEarningsReport.ProviderIdentity(
        providerID: "another-session", providerKey: "key", machineID: "another-machine"
    )
    #expect(resolveCurrentEarningsIdentity(
        accountID: "account", providers: [mapping, conflict], daemonIdentity: daemon
    ).machineID == nil)
}
