import Foundation

enum ContributionsFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_784_381_400)
    static let previewPayoutTimestamp = timestamp.addingTimeInterval(60)
    static let previewPayoutCompletionDelay: TimeInterval = 5

    static func make(_ fixture: ContributionsFixture) -> (
        availability: ContributionsAvailability,
        snapshot: ContributionsSnapshot?,
        pulsePreview: ContributionPulsePreview?
    ) {
        switch fixture {
        case .active:
            return (.available(lastUpdated: timestamp), activeSnapshot, activePulsePreview)

        case .empty:
            return (.available(lastUpdated: timestamp), emptySnapshot, emptyPulsePreview)

        case .payoutNotReady:
            var snapshot = activeSnapshot
            snapshot.payoutReadiness = .setupRequired
            return (.available(lastUpdated: timestamp), snapshot, activePulsePreview)

        case .unavailable:
            return (
                .unavailable(message: "Preview contributions data is unavailable."),
                nil,
                nil
            )
        }
    }

    private static var activeSnapshot: ContributionsSnapshot {
        ContributionsSnapshot(
            asOf: timestamp,
            currentProviderKey: "preview-machine-key-this-mac",
            availableBalance: MicroUSD(8_750_000),
            withdrawableBalance: MicroUSD(7_500_000),
            earnedLifetime: MicroUSD(18_750_000),
            lifetimeJobs: 184,
            minimumPayout: MicroUSD(1_000_000),
            payoutReadiness: .ready,
            records: [
                record(
                    id: "contribution-006",
                    age: 1_200,
                    providerKey: "preview-machine-key-this-mac",
                    providerID: "preview-session-this-mac-new",
                    providerName: "This Mac",
                    modelID: "gpt-oss-20b",
                    modelName: "GPT OSS 20B",
                    inputTokens: 1_248,
                    outputTokens: 612,
                    amount: 425_000
                ),
                record(
                    id: "contribution-005",
                    age: 7_200,
                    providerKey: "preview-machine-key-studio",
                    providerID: "preview-session-studio-new",
                    providerName: "Studio",
                    modelID: "gemma-4-26b-qat-4bit",
                    modelName: "Gemma 4 26B",
                    inputTokens: 2_044,
                    outputTokens: 904,
                    amount: 390_000
                ),
                record(
                    id: "contribution-004",
                    age: 14_400,
                    providerKey: "preview-machine-key-this-mac",
                    providerID: "preview-session-this-mac-new",
                    providerName: "This Mac",
                    modelID: "gpt-oss-20b",
                    modelName: "GPT OSS 20B",
                    inputTokens: 932,
                    outputTokens: 438,
                    amount: 310_000
                ),
                record(
                    id: "contribution-003",
                    age: 86_400,
                    providerKey: "preview-machine-key-studio",
                    providerID: "preview-session-studio-new",
                    providerName: "Studio",
                    modelID: "gemma-4-26b-qat-4bit",
                    modelName: "Gemma 4 26B",
                    inputTokens: 1_584,
                    outputTokens: 740,
                    amount: 285_000
                ),
                record(
                    id: "contribution-002",
                    age: 172_800,
                    providerKey: "preview-machine-key-this-mac",
                    providerID: "preview-session-this-mac-old",
                    providerName: "This Mac",
                    modelID: "gpt-oss-20b",
                    modelName: "GPT OSS 20B",
                    inputTokens: 768,
                    outputTokens: 352,
                    amount: 245_000
                ),
                record(
                    id: "contribution-001",
                    age: 259_200,
                    providerKey: "preview-machine-key-studio",
                    providerID: "preview-session-studio-old",
                    providerName: "Studio",
                    modelID: "gemma-4-26b-qat-4bit",
                    modelName: "Gemma 4 26B",
                    inputTokens: 2_312,
                    outputTokens: 1_096,
                    amount: 465_000
                ),
            ]
        )
    }

    private static var emptySnapshot: ContributionsSnapshot {
        ContributionsSnapshot(
            asOf: timestamp,
            currentProviderKey: "preview-machine-key-this-mac",
            availableBalance: .zero,
            withdrawableBalance: .zero,
            earnedLifetime: .zero,
            lifetimeJobs: 0,
            minimumPayout: MicroUSD(1_000_000),
            payoutReadiness: .ready,
            records: []
        )
    }

    private static var activePulsePreview: ContributionPulsePreview {
        pulsePreview(amountsAndJobs: [
            (320_000, 4),
            (410_000, 5),
            (0, 0),
            (780_000, 8),
            (640_000, 7),
            (925_000, 9),
            (1_125_000, 11),
        ])
    }

    private static var emptyPulsePreview: ContributionPulsePreview {
        pulsePreview(amountsAndJobs: Array(repeating: (0, 0), count: 7))
    }

    private static func pulsePreview(
        amountsAndJobs: [(amount: Int64, jobs: Int64)]
    ) -> ContributionPulsePreview {
        ContributionPulsePreview(
            generatedAt: timestamp,
            points: amountsAndJobs.enumerated().map { index, point in
                ContributionPulsePreviewPoint(
                    date: timestamp.addingTimeInterval(TimeInterval(index - 6) * 86_400),
                    amount: MicroUSD(point.amount),
                    jobs: point.jobs
                )
            }
        )
    }

    private static func record(
        id: String,
        age: TimeInterval,
        providerKey: String,
        providerID: String,
        providerName: String,
        modelID: String,
        modelName: String,
        inputTokens: UInt64,
        outputTokens: UInt64,
        amount: Int64
    ) -> ContributionRecord {
        ContributionRecord(
            id: id,
            timestamp: timestamp.addingTimeInterval(-age),
            providerKey: providerKey,
            providerID: providerID,
            providerName: providerName,
            modelID: modelID,
            modelName: modelName,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            amount: MicroUSD(amount)
        )
    }
}
