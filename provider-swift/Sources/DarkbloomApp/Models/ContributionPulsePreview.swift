import Foundation

/// UI-only sample data for exploring the eventual contribution history chart.
/// This type is deliberately not `Codable`: it is not part of the coordinator
/// contributions contract and must never be presented as observed account data.
struct ContributionPulsePreview: Equatable, Sendable {
    var generatedAt: Date
    var points: [ContributionPulsePreviewPoint]

    init(generatedAt: Date, points: [ContributionPulsePreviewPoint]) {
        precondition(
            points.count == 7 &&
                points.allSatisfy { $0.jobs >= 0 } &&
                zip(points, points.dropFirst()).allSatisfy { $0.date < $1.date },
            "A contribution pulse preview requires seven ordered, nonnegative samples"
        )
        self.generatedAt = generatedAt
        self.points = points
    }
}

struct ContributionPulsePreviewPoint: Equatable, Identifiable, Sendable {
    var date: Date
    var amount: MicroUSD
    var jobs: Int64

    var id: Date { date }
}
