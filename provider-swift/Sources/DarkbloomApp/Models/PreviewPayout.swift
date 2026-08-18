import Foundation

/// Local-only interaction state used while the app has no payout service adapter.
/// These types are intentionally separate from coordinator contribution records.
struct PreviewPayoutRequest: Equatable, Identifiable, Sendable {
    var id: String
    var requestedAt: Date
    var amount: MicroUSD
}

struct PreviewPayoutReceipt: Equatable, Identifiable, Sendable {
    var id: String
    var requestedAt: Date
    var completedAt: Date
    var amount: MicroUSD
}

enum PreviewPayoutState: Equatable, Sendable {
    case idle
    case submitting(PreviewPayoutRequest)
    case completed(PreviewPayoutReceipt)
}

enum PayoutValidationError: Error, Equatable, Sendable {
    case unavailable
    case setupRequired
    case nonPositive
    case belowMinimum(minimum: MicroUSD)
    case exceedsWithdrawable(withdrawable: MicroUSD)
    case alreadySubmitting
}

enum PreviewPayoutRequestResult: Equatable, Sendable {
    case accepted(PreviewPayoutRequest)
    case rejected(PayoutValidationError)
}
