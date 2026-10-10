import Foundation

/// The snapshot with its free text cleaned: see `ClusterConsoleFreeText`.
/// Everything else in a snapshot is a name, a digest, a number or a state.
extension ClusterDiagnosticsReport {
    func cleaned(_ clean: ClusterConsoleFreeText) -> ClusterDiagnosticsReport {
        ClusterDiagnosticsReport(self, checks: checks.map { .init(name: $0.name, outcome: $0.outcome, detail: clean($0.detail)) })
    }

    /// The same report with other check details. The link checks are already
    /// among `checks`, so none is derived again.
    private init(_ other: ClusterDiagnosticsReport, checks: [Check]) {
        operation = other.operation; configurationState = other.configurationState
        saved = other.saved; live = other.live; deviceJournal = other.deviceJournal
        self.checks = checks
        localLinkInspectionPerformed = other.localLinkInspectionPerformed
    }
}

extension ClusterConsoleTrust {
    func cleaned(_ clean: ClusterConsoleFreeText) -> ClusterConsoleTrust {
        .init(knownHostsPinSHA256: knownHostsPinSHA256, knownHostsPinMatches: knownHostsPinMatches, hostKeys: hostKeys,
            hostKeysNotShown: hostKeysNotShown, identityFileUsable: identityFileUsable, error: clean(error))
    }
}

extension ClusterConsolePairing {
    func cleaned(_ clean: ClusterConsoleFreeText) -> ClusterConsolePairing {
        .init(clusterID: clusterID, memberID: memberID, role: role, localRank: localRank, peerID: peerID, peerRank: peerRank,
            linkDevice: linkDevice, trust: trust.cleaned(clean), pairApproval: pairApproval)
    }
}

extension ClusterConsoleInstalled {
    func cleaned(_ clean: ClusterConsoleFreeText) -> ClusterConsoleInstalled {
        .init(workerBinary: .init(verified: workerBinary.verified, detail: clean(workerBinary.detail)),
            hasProgressGuard: hasProgressGuard, acceptsStartupDeadline: acceptsStartupDeadline,
            manifest: .init(verified: manifest.verified, detail: clean(manifest.detail)), artifactFiles: artifactFiles,
            holdings: holdings.map { .init(holdings: $0.holdings, detail: clean($0.detail)) })
    }
}

extension ClusterConsoleSavedSetup {
    func cleaned(_ clean: ClusterConsoleFreeText) -> ClusterConsoleSavedSetup {
        .init(state: state, error: clean(error), configurationSHA256: configurationSHA256,
            pairing: pairing?.cleaned(clean), model: model, installed: installed?.cleaned(clean))
    }
}

extension ClusterConsoleCandidateSetup {
    func cleaned(_ clean: ClusterConsoleFreeText) -> ClusterConsoleCandidateSetup {
        .init(error: clean(error), pairing: pairing?.cleaned(clean), publicModelID: publicModelID,
            runtimeModelID: runtimeModelID, configurationSHA256: configurationSHA256, alreadySaved: alreadySaved)
    }
}
