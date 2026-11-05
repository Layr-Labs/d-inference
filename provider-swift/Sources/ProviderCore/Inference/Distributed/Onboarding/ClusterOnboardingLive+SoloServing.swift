import Foundation

/// Single-Mac serving on either Mac of the pair (`ClusterOnboardingSoloServing`): read before the pair's parts start and
/// while the start waits, and stopped on both Macs only when the person chose it on screen.
extension OnboardingLive {
    /// This Mac's single-Mac provider (its provider instance lock), then the other Mac's (its status over the cable; a
    /// Mac that doesn't answer, or an older build that doesn't say, adds none).
    func soloServing() -> [ClusterOnboardingSoloServing] {
        var found = [ClusterOnboardingSoloServing]()
        let status = (try? command(.init(op: .status), seconds: 10)).flatMap { try? JSONDecoder().decode(ClusterServiceStatus.self, from: $0) }
        // Macs on different versions can't pair whatever single-Mac serving does: that ✗ comes first, never this one.
        guard ClusterOnboardingSoloServing.blockApplies(thisVersion: ProviderCore.version, otherVersion: status?.pairUpdate?.running)
        else { return [] }
        if let holder = ProviderInstanceHolder.singleMacServing() { found.append(.init(mac: here, pid: holder.pid)) }
        if let solo = status?.soloServing { found.append(.init(mac: there, pid: solo.pid)) }
        return found
    }

    /// The leading Mac's start stopped at the single-Mac block (true), or went past it (false): `localStatus` says the block.
    func markSoloBlocked(_ blocked: Bool) {
        try? store.updateRecord { $0.soloBlockedAt = blocked ? Date().timeIntervalSince1970 : nil }
    }

    /// The start's failure while single-Mac serving blocks the pair; nil when none does.
    func soloServingFailure() -> ClusterOnboardingFailure? {
        let found = soloServing()
        return found.isEmpty ? nil : .soloServing(found)
    }

    /// Stops single-Mac serving on each Mac that runs it, as `darkbloom stop --solo` there does (its accepted requests
    /// finish first): this Mac's here, the other Mac's by its cluster service. Asked only after the person chose it.
    func stopSoloServing() -> Result<[String], ClusterOnboardingFailure> {
        var said = [String]()
        if ProviderInstanceHolder.singleMacServing() != nil {
            switch ClusterService.stopSoloServing(executable: settings.service.wizard.darkbloomExecutable) {
            case .success: said.append("\u{2713} Stopped single-Mac serving on \(here).")
            case .failure(let failure):
                return .failure(.init("Could not stop single-Mac serving on \(here): \(failure.text)"))
            }
        }
        let otherServes: Bool = {
            guard let data = try? command(.init(op: .status), seconds: 10),
                  let status = try? JSONDecoder().decode(ClusterServiceStatus.self, from: data) else { return false }
            return status.soloServing != nil
        }()
        if otherServes {
            do {
                _ = try command(.init(op: .stopSolo), seconds: Double(ClusterService.soloStopSeconds + 30))
                said.append("\u{2713} Stopped single-Mac serving on \(there).")
            } catch {
                let reason = (error as? ClusterSetupFailure)?.text ?? "\(error)"
                return .failure(.init(said + ["Could not stop single-Mac serving on \(there): \(reason). "
                    + "Run `\(Self.cli) stop --solo` on that Mac."]))
            }
        }
        return .success(said)
    }
}
