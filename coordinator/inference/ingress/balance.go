package ingress

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
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
	policy                dispatch.RoutePolicy
}

// reserveInferenceBalance performs the shared pre-flight balance reservation +
// per-key spend cap for both inference handlers. Self-route (policy.Enabled) and
// a nil billing backend skip it (the request is free). On a spend-cap or
// insufficient-funds rejection it writes the exact terminal response and returns
// handled=true; otherwise it returns the reserved amount and whether it was a
// service-account reservation. The post-inference charge refunds any unused
// portion; the routing estimate is kept separate so capacity checks aren't
// over-inflated.
func (s *Controller) reserveInferenceBalance(w http.ResponseWriter, r *http.Request, parsed map[string]any, p balanceReservationParams) (reservedMicroUSD int64, serviceReservation bool, handled bool) {
	// Self-route is free: skip the pre-flight balance reservation and the
	// per-key spend cap entirely. A zero-balance owner must never be blocked
	// from running on their own machine, and a self_route_only key never spends.
	if !s.deps.BillingConfigured() || p.policy.Enabled {
		return 0, false, false
	}
	consumerKey := requestcontext.AccountID(r.Context())
	// Normally the byte-count billing bound dominates the routing estimate. A
	// remote media URL is the exception: its short URL is rewritten after this
	// gate into hundreds/thousands of vision soft tokens. Reserve against the
	// larger bound so a low-balance caller cannot trigger coordinator egress and
	// only then fail the platform-price balance check.
	reservationPromptTokens := max(p.billingPromptTokens, p.estimatedPromptTokens)
	reservedMicroUSD = s.deps.Settlement().Estimate(p.model, reservationPromptTokens, p.requestedMaxTokens)
	// Per-key spend cap (phase 1) — checked before the reservation so a capped
	// key never debits the account ledger.
	if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:               r,
			Stage:                 "balance",
			ReasonCode:            "insufficient_quota",
			HttpStatus:            http.StatusPaymentRequired,
			KeyID:                 requestcontext.KeyID(r.Context()),
			ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:        p.publicModel,
			ResolvedModel:         p.model,
			Stream:                p.stream,
			EstimatedPromptTokens: p.estimatedPromptTokens,
			RequestedMaxTokens:    p.requestedMaxTokens,
			RequiresVision:        p.requiresVision,
			HasTools:              p.hasTools,
			Params:                rejectionSamplingParams(parsed),
		})
		httpresponse.WriteJSON(w, http.StatusPaymentRequired, httpresponse.ErrorBody("insufficient_quota", msg, httpresponse.WithCode("insufficient_quota")))
		return reservedMicroUSD, false, true
	}
	var err error
	serviceReservation, err = s.deps.Settlement().Reserve(consumerKey, p.model, reservedMicroUSD)
	if err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			s.deps.Observer.Rejection(dispatch.Rejection{
				Request:               r,
				Stage:                 "balance",
				ReasonCode:            "insufficient_funds",
				HttpStatus:            http.StatusPaymentRequired,
				KeyID:                 requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
				RequestedModel:        p.publicModel,
				ResolvedModel:         p.model,
				Stream:                p.stream,
				EstimatedPromptTokens: p.estimatedPromptTokens,
				RequestedMaxTokens:    p.requestedMaxTokens,
				RequiresVision:        p.requiresVision,
				HasTools:              p.hasTools,
				Params:                rejectionSamplingParams(parsed),
			})
			httpresponse.WriteJSON(w, http.StatusPaymentRequired, httpresponse.ErrorBody("insufficient_funds",
				"your balance is too low for this request — add funds at /billing or lower max_tokens", httpresponse.WithCode("insufficient_quota")))
		} else {
			s.deps.Logger().Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
			s.writeServiceUnavailable(w, p.model)
		}
		return reservedMicroUSD, serviceReservation, true
	}
	return reservedMicroUSD, serviceReservation, false
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
func (s *Controller) topUpReservationForInlinedMedia(w http.ResponseWriter, r *http.Request, parsed map[string]any, p balanceReservationParams, currentMicroUSD int64) (reservedMicroUSD int64, handled bool) {
	// Same skips as reserveInferenceBalance: self-route is free and a nil billing
	// backend never reserved anything to top up.
	if !s.deps.BillingConfigured() || p.policy.Enabled || currentMicroUSD <= 0 {
		return currentMicroUSD, false
	}
	want := s.deps.Settlement().Estimate(p.model, max(p.billingPromptTokens, p.estimatedPromptTokens), p.requestedMaxTokens)
	if want <= currentMicroUSD {
		return currentMicroUSD, false
	}
	reject := func(reasonCode, code, msg string) {
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:               r,
			Stage:                 "balance",
			ReasonCode:            reasonCode,
			HttpStatus:            http.StatusPaymentRequired,
			KeyID:                 requestcontext.KeyID(r.Context()),
			ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:        p.publicModel,
			ResolvedModel:         p.model,
			Stream:                p.stream,
			EstimatedPromptTokens: p.estimatedPromptTokens,
			RequestedMaxTokens:    p.requestedMaxTokens,
			RequiresVision:        p.requiresVision,
			HasTools:              p.hasTools,
			Params:                rejectionSamplingParams(parsed),
		})
		s.deps.Metrics.Incr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:rejected"})
		httpresponse.WriteJSON(w, http.StatusPaymentRequired, httpresponse.ErrorBody(code, msg, httpresponse.WithCode("insufficient_quota")))
	}
	// Cap check against the new TOTAL, matching Service.ReserveForProvider.
	if msg, ok := s.checkKeySpendCap(r.Context(), want); !ok {
		reject("insufficient_quota", "insufficient_quota", msg)
		return currentMicroUSD, true
	}
	consumerKey := requestcontext.AccountID(r.Context())
	// Charge only the delta; Service.Reserve re-derives the same
	// service-vs-ledger mode for this account, so the hold stays consistent.
	if _, err := s.deps.Settlement().Reserve(consumerKey, p.model, want-currentMicroUSD); err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			reject("insufficient_funds", "insufficient_funds",
				"your balance is too low for this request once the linked media is included — add funds at /billing, use smaller media, or lower max_tokens")
		} else {
			s.deps.Logger().Error("media reservation top-up failed (DB error)", "consumer_key", consumerKey, "error", err)
			s.deps.Metrics.Incr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:error"})
			s.writeServiceUnavailable(w, p.model)
		}
		return currentMicroUSD, true
	}
	s.deps.Metrics.Incr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:reserved"})
	return want, false
}
