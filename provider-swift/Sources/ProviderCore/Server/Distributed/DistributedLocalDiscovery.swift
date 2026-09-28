import Foundation

/// The CLI's existing exclusive serving/PID lock must cover publication and
/// removal. Conditional removal also preserves a different record encountered
/// during teardown; it is not a lock against arbitrary same-user file writers.
struct DistributedLocalDiscovery: Sendable {
    let publish: @Sendable (LocalEndpoint.Info) throws -> Void
    let removeIfOwned: @Sendable (LocalEndpoint.Info) -> Void

    static let local = Self(publish: { try LocalEndpoint.writeInfo($0) }, removeIfOwned: { owned in
        remove(owned, read: LocalEndpoint.readInfo, remove: LocalEndpoint.removeInfo)
    })

    static func remove(_ owned: LocalEndpoint.Info, read: () -> LocalEndpoint.Info?, remove: () -> Void) {
        guard read() == owned else { return }
        remove()
    }
}
