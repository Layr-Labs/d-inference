package metrics

// BillingMetrics is the money path: what was reserved, what was charged, what
// was given back, and every place the coordinator decided not to collect. These
// are the series a discrepancy between the ledger and Stripe is investigated
// with, so the sums matter more than the rates: a micro-USD counter is the
// authoritative-ish record of what the metric pipeline saw, and a gap in it is a
// gap in that account.
//
// `model` is a catalog model id, never a caller's alias. `mode` is the
// reservation mechanism — `service_hold` (a service consumer's hold, no ledger
// movement) or `ledger` (a real debit) — and it is on every reservation series
// because the two have different failure modes and only one can leave money
// stranded.
type BillingMetrics struct {
	// Reservations is one attempt to reserve the estimated cost of a request.
	Reservations *Counter
	// ReservedMicroUSD is the amount a successful reservation held.
	ReservedMicroUSD *Distribution
	// ReservationReleases is a hold coming back for any reason; `reason`
	// separates an early release (request never dispatched) from a refund after
	// settlement.
	ReservationReleases *Counter
	// ReservationRefunds is the subset of releases that moved money back.
	ReservationRefunds *Counter
	// ReservationExtraRefunds is a second refund on one reservation. It should
	// be rare; a rate here means a release path is running twice.
	ReservationExtraRefunds *Counter
	// ReservationFinalize is a settled service hold.
	ReservationFinalize *Counter
	// MediaReservationTopup is the extra reservation a request with remote media
	// needs once the media size is known.
	MediaReservationTopup *Counter

	// ServiceSettlementMicroUSD is what a settled service hold actually cost.
	ServiceSettlementMicroUSD *Distribution
	// SettlementRefundMicroUSD is what settlement gave back when the estimate
	// exceeded the real cost.
	SettlementRefundMicroUSD *Distribution
	// OverageCharged and OverageMicroUSD are the requests that cost more than
	// was reserved. A rising overage rate means the estimator is low, and the
	// amount is the exposure that carries.
	OverageCharged  *Counter
	OverageMicroUSD *Distribution
	// CostClamped is a computed cost that hit a sanity bound. Never expected;
	// each one is a pricing or usage-reporting bug.
	CostClamped *Counter
	// ZeroUsageComplete is a completion that reported no tokens at all, so
	// nothing could be charged for work that may have been done.
	ZeroUsageComplete *Counter
	// UncollectedZeroed is a hold released without collecting, because the
	// amount owed could not be established.
	UncollectedZeroed *Counter

	// ProviderCreditsMicroUSD and PlatformFeesMicroUSD are the two halves of a
	// settled request's payout split.
	ProviderCreditsMicroUSD *Counter
	PlatformFeesMicroUSD    *Counter
	// CreditFailed is a credit the store refused. Money the coordinator believes
	// it returned and did not; `op` says which path.
	CreditFailed *Counter

	// SessionCompleteFailed is a Stripe Checkout session the coordinator could
	// not finish crediting, and ReferralApplyFailed a referral bonus that did
	// not apply. Both are user-visible money that needs a human.
	SessionCompleteFailed *Counter
	ReferralApplyFailed   *Counter
}

func newBillingMetrics(m *Metrics) *BillingMetrics {
	return &BillingMetrics{
		Reservations: m.counter("billing.reservations",
			"Reservation attempts, by outcome (reserved or rejected for insufficient balance)",
			"model", "mode", "outcome"),
		ReservedMicroUSD: m.distribution("billing.reserved_micro_usd",
			"Micro-USD held by a successful reservation",
			"model", "mode"),
		ReservationReleases: m.counter("billing.reservation_releases",
			"Holds released, by reason: early (never dispatched) or refund (after settlement)",
			"model", "mode", "reason"),
		ReservationRefunds: m.counter("billing.reservation_refunds",
			"Releases that credited money back to the account",
			"model", "mode"),
		ReservationExtraRefunds: m.counter("billing.reservation_extra_refunds",
			"A second refund against one reservation; a rate here means a release path runs twice",
			"model"),
		ReservationFinalize: m.counter("billing.reservation_finalize",
			"Service holds finalized at settlement",
			"model", "mode", "outcome"),
		MediaReservationTopup: m.counter("billing.media_reservation_topup",
			"Additional reservation for remote media, by outcome",
			"model", "outcome"),

		ServiceSettlementMicroUSD: m.distribution("billing.service_settlement_micro_usd",
			"Micro-USD a settled service hold cost",
			"model"),
		SettlementRefundMicroUSD: m.distribution("billing.settlement_refund_micro_usd",
			"Micro-USD returned when settlement came in under the reservation",
			"model"),
		OverageCharged: m.counter("billing.overage_charged",
			"Requests that cost more than was reserved",
			"model"),
		OverageMicroUSD: m.distribution("billing.overage_micro_usd",
			"Micro-USD charged beyond the reservation",
			"model"),
		CostClamped: m.counter("billing.cost_clamped",
			"Computed cost hit a sanity bound; each one is a pricing or usage-reporting bug",
			"model"),
		ZeroUsageComplete: m.counter("billing.zero_usage_complete",
			"Completions that reported no tokens, so nothing could be charged",
			"model"),
		UncollectedZeroed: m.counter("billing.uncollected_zeroed",
			"Holds released without collecting because the amount owed could not be established",
			"model", "mode"),

		ProviderCreditsMicroUSD: m.counter("billing.provider_credits_micro_usd",
			"Micro-USD credited to providers, by credit type",
			"model", "type"),
		PlatformFeesMicroUSD: m.counter("billing.platform_fees_micro_usd",
			"Micro-USD retained as platform fee",
			"model"),
		CreditFailed: m.counter("billing.credit_failed",
			"Credits the store refused, by operation; money believed returned that was not",
			"op"),

		SessionCompleteFailed: m.counter("billing.session_complete_failed",
			"Stripe Checkout sessions the coordinator could not finish crediting"),
		ReferralApplyFailed: m.counter("billing.referral_apply_failed",
			"Referral bonuses that failed to apply"),
	}
}
