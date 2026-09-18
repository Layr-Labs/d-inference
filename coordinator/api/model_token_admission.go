package api

import (
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

var errPromotionKeyLimit = errors.New("API key spend limit reached")

// Free tokens cover input first, then output. The normal minimum applies only
// when some tokens remain paid; a fully sponsored request costs its user zero.
func modelTokenQuote(model string, prompt, completion int, in, out int64, custom bool, limit *int64) store.ModelTokenQuote {
	return func(free int64) (int64, int64, error) {
		price, err := priceModelTokens(model, prompt, completion, in, out, custom, free, nil)
		if err != nil {
			return 0, 0, err
		}
		gross, paid := price.gross, price.paid
		if limit != nil && paid > *limit {
			return 0, 0, errPromotionKeyLimit
		}
		return gross, paid, nil
	}
}

func (s *Server) promotionKeyRemaining(keyID string, limit *int64, reset string) *int64 {
	if keyID == "" || limit == nil {
		return nil
	}
	remaining := max(*limit-s.store.KeySpendSince(keyID, store.KeySpendWindowStart(reset, time.Now())), 0)
	return &remaining
}

// attempted distinguishes an account/model grant (even exhausted) from normal
// paid traffic. Service users and exclusive self-route never enter this path.
func (s *Server) reserveModelTokenPromotion(w http.ResponseWriter, r *http.Request, p balanceReservationParams) (amount int64, attempted, handled bool) {
	state := modelTokenRequest(r)
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok || state == nil || s.isServiceConsumer(consumerKeyFromContext(r.Context())) {
		return 0, false, false
	}
	// A single indexed read keeps ordinary consumer traffic out of the
	// reservation transaction. Its snapshot only selects the grant; balances
	// and available tokens are always rechecked under the transactional lock.
	grants, err := backend.ListModelTokenGrants(consumerKeyFromContext(r.Context()))
	if err != nil {
		s.writeServiceUnavailable(w, p.model)
		return 0, true, true
	}
	modelID := ""
	for _, candidate := range []string{p.publicModel, p.model} {
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
	prompt := max(p.billingPromptTokens, p.estimatedPromptTokens)
	in, out, custom := s.store.GetModelPrice("platform", p.model)
	limit := s.promotionKeyRemaining(keyIDFromContext(r.Context()), keyLimitMicroFromContext(r.Context()), keyLimitResetFromContext(r.Context()))
	quote := modelTokenQuote(p.model, prompt, p.requestedMaxTokens, in, out, custom, limit)
	var freeSeen int64
	quoted := false
	wrapped := func(free int64) (int64, int64, error) { quoted = true; freeSeen = free; return quote(free) }
	id := uuid.NewString()
	reservation, err := backend.ReserveModelTokens(id, consumerKeyFromContext(r.Context()), modelID, int64(prompt)+int64(p.requestedMaxTokens), wrapped)
	if err != nil {
		// A commit acknowledgement may be lost. Release by the same durable
		// identity; never guess at a monetary refund outside that transaction.
		_, _ = backend.ReleaseModelTokenReservation(id)
		s.writePromotionAdmissionError(w, p.model, err, quoted, freeSeen)
		return 0, true, true
	}
	if reservation != nil {
		s.modelTokenActive.Store(reservation.ID, struct{}{})
		state.reservation = reservation
		return reservation.ReservedMicroUSD, true, false
	}
	return 0, false, false
}

func (s *Server) writePromotionAdmissionError(w http.ResponseWriter, model string, err error, hasGrant bool, free int64) {
	if errors.Is(err, errPromotionKeyLimit) {
		writeJSON(w, 402, errorResponse("insufficient_quota", errPromotionKeyLimit.Error(), withCode("insufficient_quota")))
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
		writeJSON(w, 402, errorResponse(code, message, withCode(code)))
		return
	}
	s.logger.Error("model token promotion admission failed", "model", model, "error", err)
	s.writeServiceUnavailable(w, model)
}

func (s *Server) topUpModelTokenPromotion(pr *registry.PendingRequest, provider *registry.Provider) (int64, error) {
	if pr.PromotionModelID != pr.Model && pr.PromotionModelID != consumerModel(pr) {
		return pr.ReservedMicroUSD, errors.New("promotion does not cover alias fallback build")
	}
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return 0, errors.New("promotion store unavailable")
	}
	in, out, custom := s.store.GetModelPrice(providerPricingKeys(provider), pr.Model)
	if !custom || pr.PromotionFreeTokens > 0 {
		in, out, custom = s.store.GetModelPrice("platform", pr.Model)
	}
	limit := s.promotionKeyRemaining(pr.KeyID, pr.KeyLimitMicroUSD, pr.KeyLimitReset)
	reservation, err := backend.TopUpModelTokenReservation(pr.ModelTokenReservationID, 0, modelTokenQuote(pr.Model, pr.EstimatedPromptTokens, pr.RequestedMaxTokens, in, out, custom, limit))
	if err != nil {
		return pr.ReservedMicroUSD, err
	}
	pr.ReservedMicroUSD = reservation.ReservedMicroUSD
	return pr.ReservedMicroUSD, nil
}
