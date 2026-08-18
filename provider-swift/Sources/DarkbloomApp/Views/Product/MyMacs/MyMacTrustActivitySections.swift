import SwiftUI

struct MyMacVerificationSection: View {
    let mac: MyMac

    var body: some View {
        MyMacDetailSection("Verification", detail: "Independent reported checks") {
            MyMacFactRow("Trust", value: trustLabel)
            MyMacFactRow("Runtime verified", value: boolean(mac.trust.runtimeVerified))
            MyMacFactRow(
                "Apple device attestation",
                value: boolean(mac.trust.appleDeviceAttestationVerified)
            )
            MyMacFactRow(
                "Secure Enclave key bound",
                value: boolean(mac.trust.secureEnclaveKeyBound)
            )
            MyMacFactRow(
                "Failed verification checks",
                value: mac.challenge.failedAttempts.formatted()
            )

            Divider()
                .padding(.vertical, 2)

            Text("Needs attention")
                .font(.caption.weight(.semibold))
            MyMacNoticeList(
                items: mac.attention.coordinatorItems,
                emptyText: "No coordinator attention items",
                tint: ProductPalette.warning
            )

            if !mac.attention.operationalNotices.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                Text("Recent observations")
                    .font(.caption.weight(.semibold))
                Text("These observations do not change the account attention count.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                MyMacNoticeList(
                    items: mac.attention.operationalNotices,
                    emptyText: "No recent observations",
                    tint: ProductPalette.warning
                )
            }
        }
    }

    private var trustLabel: String {
        switch mac.trust.level {
        case .hardware: "Hardware-backed"
        case .selfSigned: "Self-signed"
        case .none: "Not verified"
        case let .unknown(value): value == nil ? MyMacsPresentation.notReported : "Unrecognized report"
        }
    }

    private func boolean(_ value: Bool?) -> String {
        switch value {
        case true: "Yes"
        case false: "No"
        case nil: MyMacsPresentation.notReported
        }
    }
}

struct MyMacLifetimeActivitySection: View {
    let mac: MyMac

    var body: some View {
        MyMacDetailSection("Lifetime activity", detail: "Reported for this provider record") {
            MyMacFactRow("Requests served", value: int64(mac.lifetimeRequestsServed))
            MyMacFactRow("Tokens generated", value: int64(mac.lifetimeTokensGenerated))

            if let reputation = mac.reputation {
                MyMacFactRow("Reputation score", value: decimal(reputation.score))
                MyMacFactRow("Recorded jobs", value: integer(reputation.totalJobs))
                MyMacFactRow("Successful jobs", value: integer(reputation.successfulJobs))
                MyMacFactRow("Failed jobs", value: integer(reputation.failedJobs))
                MyMacFactRow("Recorded uptime", value: duration(reputation.recordedUptimeSeconds))
                MyMacFactRow(
                    "Average response time",
                    value: milliseconds(reputation.averageResponseTimeMilliseconds)
                )
                MyMacFactRow("Checks passed", value: integer(reputation.challengesPassed))
                MyMacFactRow("Checks failed", value: integer(reputation.challengesFailed))
            } else {
                MyMacFactRow("Reputation", value: MyMacsPresentation.notReported)
            }
        }
    }

    private func integer(_ value: Int?) -> String {
        value?.formatted() ?? MyMacsPresentation.notReported
    }

    private func int64(_ value: Int64?) -> String {
        value?.formatted() ?? MyMacsPresentation.notReported
    }

    private func decimal(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0 ... 3)))
            ?? MyMacsPresentation.notReported
    }

    private func duration(_ seconds: Int64?) -> String {
        guard let seconds else { return MyMacsPresentation.notReported }
        return ProductFormat.duration(TimeInterval(seconds))
    }

    private func milliseconds(_ value: Int64?) -> String {
        value.map { "\($0.formatted()) ms" } ?? MyMacsPresentation.notReported
    }
}

struct MyMacTechnicalDetails: View {
    let mac: MyMac

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                MyMacFactRow("Provider session", value: mac.providerID)
                MyMacFactRow("Backend", value: mac.backend ?? MyMacsPresentation.notReported)
                MyMacFactRow("Inventory identity", value: identitySource)
                MyMacFactRow("Provider record registered", value: date(mac.registeredAt))
            }
            .padding(.top, 10)
        } label: {
            Text("Technical details")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 5)
    }

    private var identitySource: String {
        switch mac.identity.source {
        case .serialNumber: "Serial number"
        case .secureEnclavePublicKey: "Secure Enclave public key"
        case .providerSessionID: "Provider session fallback"
        }
    }

    private func date(_ value: Date?) -> String {
        value?.formatted(date: .abbreviated, time: .shortened)
            ?? MyMacsPresentation.notReported
    }
}
