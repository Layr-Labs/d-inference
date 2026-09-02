import Foundation
import SandboxCore
import SandboxRuntime

/// Adoption of the guest vsock channel Lume patch 0005 hands over.
///
/// Patch 0005 connects to the guest's listening port once the agent binds it,
/// then passes the connected descriptor back over the inherited control socket
/// with `SCM_RIGHTS`. Until this file existed nothing on the host ever received
/// it: `SandboxManagedProcess.receiveGuestChannelDescriptor()` was public with
/// no callers, so the channel was created and immediately dropped.
///
/// Three properties of the handover shape everything here.
///
/// It is **one-shot**. Patch 0005 retries the connect on a long deadline but
/// returns after the first success, so a VM gets exactly one descriptor for the
/// life of its `lume run`. There is no reconnect: a channel that closes is gone
/// until the VM is restarted.
///
/// It is **optional**. Only a VM this process spawned can have one — a VM found
/// already running has spent its single handover, possibly in another process.
/// Absence is a normal state to be fallen back from, never an error.
///
/// It is **long-lived**. The agent serves many sequential commands on one
/// connection, so a single client is created once and multiplexes everything.
extension LumeVirtualMachineRuntime {
    /// How long to wait for the agent to bind after the VM starts.
    ///
    /// Measured on real hardware, a baked agent handshakes about nine seconds
    /// after a cold `lume run`, because a system-domain LaunchDaemon starts
    /// well before the login window. This budget is generous against that and
    /// still far short of the readiness timeout, so a guest without a working
    /// agent falls back rather than stalling the start.
    static let guestChannelAdoptionBudget: Duration = .seconds(45)
    static let guestChannelPollInterval: Duration = .milliseconds(50)

    /// Takes ownership of the descriptor for a VM we spawned, or gives up.
    ///
    /// Returns `nil` for every "there is no channel" outcome, which the caller
    /// treats as a guest that speaks SSH only.
    func adoptGuestChannel(
        name: String,
        process: SandboxManagedProcess,
        within budget: Duration = LumeVirtualMachineRuntime
            .guestChannelAdoptionBudget
    ) async -> SandboxGuestChannelClient? {
        if let existing = guestChannels[name] {
            return existing
        }
        // No device was attached, so no descriptor is ever coming and polling
        // would just add latency to every start on an agentless image.
        guard configuration.guestChannelPort != nil else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)

        while clock.now < deadline {
            let descriptor: Int32?
            do {
                descriptor = try process.receiveGuestChannelDescriptor()
            } catch {
                // The control socket failed. No descriptor is coming.
                return nil
            }

            if let descriptor {
                return adopt(descriptor: descriptor, name: name)
            }

            // `nil` is ambiguous by construction: not arrived yet, the child
            // exited, or the single handover already happened. Only the first
            // is worth waiting on, and a dead child distinguishes the others.
            guard process.isRunning else { return nil }
            try? await Task.sleep(for: Self.guestChannelPollInterval)
        }
        return nil
    }

    /// Wraps a received descriptor, closing it if the client cannot take it.
    ///
    /// `SandboxGuestChannelClient.init` throws *before* storing the descriptor,
    /// so its `deinit` never runs and the fd would leak for the life of the
    /// daemon. Ownership transferred to us on receipt, so closing it is ours to
    /// do.
    func adopt(
        descriptor: Int32,
        name: String
    ) -> SandboxGuestChannelClient? {
        do {
            let client = try SandboxGuestChannelClient(descriptor: descriptor)
            guestChannels[name] = client
            return client
        } catch {
            Darwin.close(descriptor)
            return nil
        }
    }

    /// The channel for a VM, if it has one.
    func guestChannel(for name: String) -> SandboxGuestChannelClient? {
        guestChannels[name]
    }

    /// Closes and forgets a VM's channel.
    ///
    /// Closed explicitly rather than left to ARC: `LumeGuestVsockTransport` is
    /// a struct holding a strong reference, so a transport value still in
    /// flight can outlive the dictionary entry and keep the descriptor open
    /// past the point the VM is gone.
    ///
    /// Safe to call for a VM that never had a channel, which is what lets every
    /// teardown path call it unconditionally.
    func releaseGuestChannel(name: String) {
        guestChannels.removeValue(forKey: name)?.close()
    }
}
