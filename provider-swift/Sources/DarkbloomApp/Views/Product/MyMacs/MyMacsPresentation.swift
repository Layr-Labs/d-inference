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

    static func isThisMac(_ mac: MyMac, currentSerialNumber: String?) -> Bool {
        guard let currentSerialNumber, !currentSerialNumber.isEmpty else { return false }
        return mac.serialNumber == currentSerialNumber
    }

    static func defaultSelection(
        in macs: [MyMac],
        currentSerialNumber: String?
    ) -> String? {
        if let thisMac = macs.first(where: {
            isThisMac($0, currentSerialNumber: currentSerialNumber)
        }) {
            return thisMac.id
        }
        if let connected = macs.first(where: { $0.lifecycle.isOperationallyConnected }) {
            return connected.id
        }
        return macs.max(by: {
            ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast)
        })?.id
    }

    static func filtered(
        _ macs: [MyMac],
        searchText: String,
        status: MyMacsStatusFilter,
        attention: MyMacsAttentionFilter
    ) -> [MyMac] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return macs.filter { mac in
            guard status.includes(mac.lifecycle) else { return false }
            if attention == .needsAttention, !mac.attention.requiresAttention {
                return false
            }
            guard !query.isEmpty else { return true }

            return searchableValues(for: mac).contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    /// A Mac is named by its reported machine model. The chip belongs on the
    /// supporting line so the inventory remains scannable by physical form.
    static func title(for mac: MyMac) -> String {
        mac.hardware?.machineModel ?? "Mac"
    }

    /// Duplicate reported machine models gain only a privacy-preserving serial
    /// suffix. Unique machine models never expose identifier material in their
    /// default title.
    static func title(for mac: MyMac, in fleet: [MyMac]) -> String {
        let baseTitle = title(for: mac)
        let duplicateCount = fleet.count {
            title(for: $0).localizedCaseInsensitiveCompare(baseTitle) == .orderedSame
        }
        guard duplicateCount > 1, let suffix = mac.maskedSerialNumber else {
            return baseTitle
        }
        return "\(baseTitle) · \(suffix)"
    }

    /// The bloomline has less horizontal room than the inventory. Preserve the
    /// same privacy-safe four-character suffix without spending width on the
    /// mask glyphs; the complete masked title remains available on hover and
    /// to assistive technology.
    static func bloomlineTitle(for mac: MyMac, in fleet: [MyMac]) -> String {
        let baseTitle = title(for: mac)
        let duplicateCount = fleet.count {
            title(for: $0).localizedCaseInsensitiveCompare(baseTitle) == .orderedSame
        }
        guard duplicateCount > 1,
              let serialNumber = mac.serialNumber?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !serialNumber.isEmpty
        else {
            return baseTitle
        }
        return "\(baseTitle) · #\(serialNumber.suffix(4))"
    }

    static func supportLine(for mac: MyMac) -> String {
        let parts: [String?] = [
            mac.hardware?.chipName,
            mac.hardware?.memoryGB.map { "\($0) GB memory" },
            mac.hardware?.gpuCoreCount.map { "\($0) GPU cores" },
        ]
        let reported = parts.compactMap { $0 }
        return reported.isEmpty ? notReported : reported.joined(separator: " · ")
    }

    /// The narrow inventory keeps only the primary hardware discriminator.
    /// Memory and GPU detail are presented in the selected Mac pane.
    static func inventorySupportLine(for mac: MyMac) -> String {
        mac.hardware?.chipName ?? notReported
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
            "This Mac is currently serving requests."
        case .online:
            "Connected to Darkbloom and not currently serving."
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
            mac.serialNumber,
            mac.maskedSerialNumber,
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
