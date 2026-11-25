import Foundation

/// Whether the connected coordinator advertised one optional behaviour in its
/// latest `trust_status.coordinator_features`. False until it does, and again
/// after a disconnect or a `trust_status` without it.
final class CoordinatorFeatureAdvertisement: @unchecked Sendable {
    let feature: String
    private let lock = NSLock()
    private var advertised = false

    init(feature: String) {
        self.feature = feature
    }

    var value: Bool { lock.withLock { advertised } }

    /// From one `trust_status`: nil (an older coordinator) or a list without
    /// the feature turns it off.
    func update(features: [String]?) {
        let present = features?.contains(feature) ?? false
        lock.withLock { advertised = present }
    }

    func reset() { lock.withLock { advertised = false } }
}
