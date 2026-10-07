package inference

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// balanceReservationParams bundles the inputs to the shared pre-flight balance
// reservation.
type balanceReservationParams struct {
	model                 string
	publicModel           string
	billingPromptTokens   int
	estimatedPromptTokens int
	requestedMaxTokens    int
	stream                bool
	requiresVision        bool
	hasTools              bool
	policy                selfRoutePolicy
}

func (s *Owner) reserveInferenceBalance(w http.ResponseWriter, r *http.Request, parsed map[string]any, p balanceReservationParams) (int64, bool, bool) {
	return s.reservations.Reserve(w, r, parsed, reservationParams(p))
}

// topUpReservationForInlinedMedia re-reserves after remote media has been
// fetched and inlined into parsed.
//
// reserveInferenceBalance runs BEFORE the fetch (deliberately — network I/O must
// stay behind the cost gates), so for a remote media URL it reserves against a
// body where the image is ~100 bytes of URL text. That breaks the invariant the
// rest of the money path depends on: estimateBillingPromptTokens is documented
// as a guaranteed upper bound (len(bytes) >= tokens for any BPE tokenizer), and
// for an inline data: URI it is. The flat routing floor (300 image / 1500 video
// soft tokens) is NOT an upper bound — a provider samples up to 32 video frames
// at ~282 soft tokens each — and settlement clamps any overage at 2x the
// reservation as a fraud circuit-breaker, so the shortfall is silently written
// off AND the provider payout is recomputed from the clamped total. Recomputing
// the byte bound over the inlined body restores the guarantee.
//
// p.billingPromptTokens must already be recomputed from the mutated parsed.
// Returns the reservation now held (unchanged when no top-up was needed or when
// the top-up failed) and handled=true after writing a terminal response, in
// which case the caller must refund and return.
func (s *Owner) topUpReservationForInlinedMedia(w http.ResponseWriter, r *http.Request, parsed map[string]any, p balanceReservationParams, currentMicroUSD int64) (reservedMicroUSD int64, handled bool) {
	if reservation := modelTokenReservation(r); reservation != nil {
		return s.promotions.TopUpRequest(w, r, promotionAdmission(p), currentMicroUSD)
	}

	// Same skips as reserveInferenceBalance: self-route is free and a nil billing
	// backend never reserved anything to top up.
	if s.billing == nil || p.policy.enabled || currentMicroUSD <= 0 {
		return currentMicroUSD, false
	}
	want := s.reservationCost(p.model, max(p.billingPromptTokens, p.estimatedPromptTokens), p.requestedMaxTokens)
	if want <= currentMicroUSD {
		return currentMicroUSD, false
	}
	reject := func(reasonCode, code, msg string) {
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "balance",
			reasonCode:            reasonCode,
			httpStatus:            http.StatusPaymentRequired,
			keyID:                 access.KeyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:        p.publicModel,
			resolvedModel:         p.model,
			stream:                p.stream,
			estimatedPromptTokens: p.estimatedPromptTokens,
			requestedMaxTokens:    p.requestedMaxTokens,
			requiresVision:        p.requiresVision,
			hasTools:              p.hasTools,
			params:                rejectionSamplingParams(parsed),
		})
		s.observation.Incr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:rejected"})
		httpx.WriteJSON(w, http.StatusPaymentRequired, httpx.ErrorResponse(code, msg, httpx.WithCode("insufficient_quota")))
	}
	// Cap check against the new TOTAL, matching reserveAdditionalForProvider.
	if msg, ok := s.checkKeySpendCap(r.Context(), want); !ok {
		reject("insufficient_quota", "insufficient_quota", msg)
		return currentMicroUSD, true
	}
	consumerKey := access.ConsumerKeyFromContext(r.Context())
	// Charge only the delta; reserveInitialBalance re-derives the same
	// service-vs-ledger mode for this account, so the hold stays consistent.
	if _, err := s.reserveInitialBalance(consumerKey, p.model, want-currentMicroUSD); err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			reject("insufficient_funds", "insufficient_funds",
				"your balance is too low for this request once the linked media is included — add funds at /billing, use smaller media, or lower max_tokens")
		} else {
			s.logger.Error("media reservation top-up failed (DB error)", "consumer_key", consumerKey, "error", err)
			s.observation.Incr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:error"})
			s.writeServiceUnavailable(w, p.model)
		}
		return currentMicroUSD, true
	}
	s.observation.Incr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:reserved"})
	return want, false
}
