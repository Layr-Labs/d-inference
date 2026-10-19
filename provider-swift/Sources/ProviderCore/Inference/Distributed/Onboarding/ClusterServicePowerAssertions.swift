import Foundation

/// Owned and updated only by the service's supervision thread. A saved serving
/// deployment stays awake between requests and while waiting for a peer to return.
final class ClusterServicePowerAssertions {
    private let inference: InferencePowerAssertion
    private let network: NetworkPowerAssertion
    private var serving = false
    private var held = false

    convenience init(reason: String = "Darkbloom cluster: serving deployment") {
        self.init(inference: InferencePowerAssertion(reason: reason), network: NetworkPowerAssertion(reason: reason))
    }

    init(inference: InferencePowerAssertion, network: NetworkPowerAssertion) {
        self.inference = inference
        self.network = network
    }

    /// Nil means the setup could not be read, not that serving was stopped.
    func update(savedServing: Bool?, partRunning: Bool, relayRunning: Bool) {
        if let savedServing { serving = savedServing }
        let needed = serving || partRunning || relayRunning
        if needed {
            // `held` is our retain, not proof that macOS granted every assertion.
            if held { inference.ensureAcquired() }
            else { inference.acquire(); held = true }
            network.acquire()
        } else { release() }
    }

    func release() {
        serving = false
        guard held else { return }
        held = false
        inference.release()
        network.release()
    }

    deinit { release() }
}
