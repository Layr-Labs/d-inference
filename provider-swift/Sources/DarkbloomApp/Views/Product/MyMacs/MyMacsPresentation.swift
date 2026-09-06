import Foundation

enum MyMacsStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case connected
    case serving
    case offline
    case verification

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All statuses"
        case .connected: "Connected"
        case .serving: "Serving now"
        case .offline: "Offline"
        case .verification: "Verification required"
        }
    }

    func includes(_ lifecycle: MyMacLifecycle) -> Bool {
        switch self {
        case .all:
            true
        case .connected:
            lifecycle == .serving || lifecycle == .online
        case .serving:
            lifecycle == .serving
        case .offline:
            lifecycle == .offline || lifecycle == .neverSeen
        case .verification:
            lifecycle == .untrusted
        }
    }
}

enum MyMacsAttentionFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case needsAttention = "needs-attention"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Macs"
        case .needsAttention: "Needs attention"
        }
    }
}

enum MyMacsPresentation {
    static let notReported = "Not reported"

    static func defaultSelection(in macs: [MyMac]) -> String? {
        if let connected = macs.first(where: { $0.lifecycle.isOperationallyConnected }) {
            return connected.id
        }
        return macs.max(by: {
            ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast)
        })?.id
    }

    static func reconciledSelection(_ selection: String?, in macs: [MyMac]) -> String? {
        if let selection, macs.contains(where: { $0.id == selection }) {
            return selection
        }
        return defaultSelection(in: macs)
    }

    static func filtered(
        _ macs: [MyMac],
        searchText: String,
        status: MyMacsStatusFilter,
        attention: MyMacsAttentionFilter
    ) -> [MyMac] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitles = query.isEmpty ? [:] : titles(in: macs)
        return macs.filter { mac in
            guard status.includes(mac.lifecycle) else { return false }
            if attention == .needsAttention, !mac.attention.requiresAttention {
                return false
            }
            guard !query.isEmpty else { return true }

            return ([displayTitles[mac.id] ?? title(for: mac)] + searchableValues(for: mac)).contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    /// Name Macs by reported model; hardware specifications belong in detail.
    static func title(for mac: MyMac) -> String {
        mac.hardware?.machineModel ?? "Mac"
    }

    /// Duplicate model names use an account-local ordinal, sorted by opaque
    /// ID so filtering and response ordering cannot rename a selected Mac.
    /// No hardware identifiers become display names or searchable metadata.
    static func title(for mac: MyMac, in fleet: [MyMac]) -> String {
        titles(in: fleet)[mac.id] ?? title(for: mac)
    }

    /// Compute once per fleet/search pass so large duplicate-model fleets do
    /// not repeatedly sort the full inventory for every rendered row.
    static func titles(in fleet: [MyMac]) -> [String: String] {
        let groups = Dictionary(grouping: fleet) {
            title(for: $0).folding(options: .caseInsensitive, locale: .current)
        }
        var titles: [String: String] = [:]
        for peers in groups.values {
            for (index, mac) in peers.sorted(by: { $0.providerID < $1.providerID }).enumerated() {
                let base = title(for: mac)
                titles[mac.id] = peers.count > 1 ? "\(base) · \(index + 1)" : base
            }
        }
        return titles
    }

    static func supportLine(for mac: MyMac) -> String {
        mac.hardware?.chipName ?? "Chip not reported"
    }

    static func lifecycleTitle(_ lifecycle: MyMacLifecycle) -> String {
        switch lifecycle {
        case .serving: "Serving now"
        case .online: "Connected"
        case .offline: "Offline"
        case .neverSeen: "Awaiting reconnection"
        case .untrusted: "Verification required"
        case .unknown: "Status unavailable"
        }
    }

    static func lifecycleDetail(_ mac: MyMac) -> String {
        switch mac.lifecycle {
        case .serving:
            "Serving requests at the last update."
        case .online:
            "Connected and not serving requests at the last update."
        case .offline:
            mac.lastSeen.map { "Last reported \(relativeDate($0))." }
                ?? "The last report time was not provided."
        case .neverSeen:
            "Not seen since the network service restarted."
        case .untrusted:
            "Darkbloom could not verify this Mac for network work."
        case .unknown:
            "The coordinator reported a status this version does not recognize."
        }
    }

    static func lifecycleSymbol(_ lifecycle: MyMacLifecycle) -> String {
        switch lifecycle {
        case .serving: "waveform"
        case .online: "checkmark.circle.fill"
        case .offline: "moon.zzz"
        case .neverSeen: "clock.badge.questionmark"
        case .untrusted: "exclamationmark.shield.fill"
        case .unknown: "questionmark.circle"
        }
    }

    static func attentionDescription(_ reason: MyMacAttentionReason) -> String {
        switch reason {
        case .offline: "This Mac is offline."
        case .neverSeen: "This Mac has not reconnected since the network service restarted."
        case .untrusted: "This Mac requires verification."
        case .unknownLifecycle: "The reported lifecycle is not recognized."
        case .runtimeNotVerified: "The provider runtime was not verified."
        case .trustBelowHardware: "Hardware-backed trust was not reported."
        case .challengeAwaitingFirstVerification: "Waiting for the first verification check."
        case .challengeStale: "The most recent verification check is older than expected."
        case .challengeFailures: "One or more verification checks failed."
        case .providerBelowMinimumVersion: "The installed provider is below the minimum version."
        case .providerUpdateAvailable: "A newer provider version is available."
        case .thermalFair: "The Mac reported elevated thermal pressure."
        case .thermalSerious: "The Mac reported serious thermal pressure."
        case .thermalCritical: "The Mac reported critical thermal pressure."
        case .backendCrashed: "A reported model process crashed."
        case .backendCold: "A reported model process is not currently resident."
        case .noCatalogModels: "No models were advertised."
        }
    }

    static func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private static func searchableValues(for mac: MyMac) -> [String] {
        var values = [
            title(for: mac),
            mac.hardware?.machineModel,
            mac.hardware?.chipName,
            mac.providerID,
            mac.version.installed,
            lifecycleTitle(mac.lifecycle),
        ].compactMap { $0 }

        values.append(contentsOf: mac.models?.map(\.id) ?? [])
        switch mac.live?.capacity {
        case let .backendSlots(capacity):
            values.append(contentsOf: capacity.slots.map(\.modelID))
        case let .legacy(capacity):
            if let current = capacity.currentModelID {
                values.append(current)
            }
            values.append(contentsOf: capacity.warmModelIDs)
        case .unavailable, nil:
            break
        }
        return values
    }
}
