package promotions

import (
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

var errPromotionKeyLimit = errors.New("API key spend limit reached")

// Free tokens cover input first, then output. The normal minimum applies only
// when some tokens remain paid; a fully sponsored request costs its user zero.
func quote(prompt, completion int, rates payments.Rates, limit *int64) store.ModelTokenQuote {
	return func(free int64) (int64, int64, error) {
		price, err := PriceTokens(prompt, completion, rates, free, nil)
		if err != nil {
			return 0, 0, err
		}
		gross, paid := price.Gross, price.Paid
		if limit != nil && paid > *limit {
			return 0, 0, errPromotionKeyLimit
		}
		return gross, paid, nil
	}
}

func (s *Engine) keyRemaining(keyID string, limit *int64, reset string) *int64 {
	if keyID == "" || limit == nil {
		return nil
	}
	remaining := max(*limit-s.store.KeySpendSince(keyID, store.KeySpendWindowStart(reset, time.Now())), 0)
	return &remaining
}

// attempted distinguishes an account/model grant (even exhausted) from normal
// paid traffic. Service users and exclusive self-route never enter this path.
func (s *Engine) Reserve(w http.ResponseWriter, r *http.Request, p Admission) (amount int64, attempted, handled bool) {
	state := modelTokenRequest(r)
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok || state == nil || s.isService(access.ConsumerKeyFromContext(r.Context())) {
		return 0, false, false
	}
	// A single indexed read keeps ordinary consumer traffic out of the
	// reservation transaction. Its snapshot only selects the grant; balances
	// and available tokens are always rechecked under the transactional lock.
	grants, err := backend.ListModelTokenGrants(access.ConsumerKeyFromContext(r.Context()))
	if err != nil {
		s.unavailable(w, p.Model)
		return 0, true, true
	}
	modelID := ""
	for _, candidate := range []string{p.PublicModel, p.Model} {
		for _, grant := range grants {
			if grant.ModelID == candidate {
				modelID = candidate
				break
			}
		}
		if modelID != "" {
			break
		}
	}
	if modelID == "" {
		return 0, false, false
	}
	prompt := max(p.BillingPromptTokens, p.EstimatedPromptTokens)
	rates := payments.RatesFor(s.store.GetModelPrice("platform", p.Model))
	limit := s.keyRemaining(access.KeyIDFromContext(r.Context()), access.KeyLimitMicroFromContext(r.Context()), access.KeyLimitResetFromContext(r.Context()))
	quote := quote(prompt, p.RequestedMaxTokens, rates, limit)
	var freeSeen int64
	quoted := false
	wrapped := func(free int64) (int64, int64, error) { quoted = true; freeSeen = free; return quote(free) }
	id := uuid.NewString()
	reservation, err := backend.ReserveModelTokens(id, access.ConsumerKeyFromContext(r.Context()), modelID, int64(prompt)+int64(p.RequestedMaxTokens), wrapped)
	if err != nil {
		// A commit acknowledgement may be lost. Release by the same durable
		// identity; never guess at a monetary refund outside that transaction.
		_, _ = backend.ReleaseModelTokenReservation(id)
		s.writeAdmissionError(w, p.Model, err, quoted, freeSeen)
		return 0, true, true
	}
	if reservation != nil {
		s.active.Store(reservation.ID, struct{}{})
		state.reservation = reservation
		return reservation.ReservedMicroUSD, true, false
	}
	return 0, false, false
}

func (s *Engine) writeAdmissionError(w http.ResponseWriter, model string, err error, hasGrant bool, free int64) {
	if errors.Is(err, errPromotionKeyLimit) {
		httpx.WriteJSON(w, 402, httpx.ErrorResponse("insufficient_quota", errPromotionKeyLimit.Error(), httpx.WithCode("insufficient_quota")))
		return
	}
	if errors.Is(err, store.ErrInsufficientBalance) {
		code, message := "insufficient_funds", "your paid balance is too low for this request — add funds in Billing"
		if hasGrant && free == 0 {
			code = "free_tokens_exhausted"
			message = fmt.Sprintf("Your free token allowance for %s is exhausted or reserved by active requests, and your paid balance cannot cover this request. Add credits in Billing or wait for active requests to finish.", model)
		}
		if hasGrant && free > 0 {
			code = "promotion_balance_required"
			message = fmt.Sprintf("Your remaining free tokens for %s cannot cover this request's maximum size, and your paid balance is too low. Lower max_tokens or add credits in Billing.", model)
		}
		httpx.WriteJSON(w, 402, httpx.ErrorResponse(code, message, httpx.WithCode(code)))
		return
	}
	s.logger.Error("model token promotion admission failed", "model", model, "error", err)
	s.unavailable(w, model)
}

func (s *Engine) TopUpProvider(pr *registry.PendingRequest, provider *registry.Provider) (int64, error) {
	if pr.PromotionModelID != pr.Model && pr.PromotionModelID != inresp.ConsumerModel(pr) {
		return pr.ReservedMicroUSD, errors.New("promotion does not cover alias fallback build")
	}
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return 0, errors.New("promotion store unavailable")
	}
	price, custom := s.store.GetModelPrice(s.providerPricingKeys(provider), pr.Model)
	if !custom || pr.PromotionFreeTokens > 0 {
		price, custom = s.store.GetModelPrice("platform", pr.Model)
	}
	limit := s.keyRemaining(pr.KeyID, pr.KeyLimitMicroUSD, pr.KeyLimitReset)
	reservation, err := backend.TopUpModelTokenReservation(pr.ModelTokenReservationID, 0, quote(pr.EstimatedPromptTokens, pr.RequestedMaxTokens, payments.RatesFor(price, custom), limit))
	if err != nil {
		return pr.ReservedMicroUSD, err
	}
	pr.ReservedMicroUSD = reservation.ReservedMicroUSD
	return pr.ReservedMicroUSD, nil
}
