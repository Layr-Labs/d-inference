package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/trial"
	"github.com/google/uuid"
)

type trialRequest struct {
	reservation     *store.TrialReservation
	committed       atomic.Bool
	unusedConfirmed atomic.Bool
}

type trialPriceSnapshot struct {
	Rates      trial.Rates `json:"rates"`
	FeePercent *int64      `json:"fee_percent,omitempty"`
}

func trialFromRequest(r *http.Request) *trialRequest {
	if r == nil {
		return nil
	}
	t, _ := r.Context().Value(ctxKeyTrial).(*trialRequest)
	return t
}

func trialReservationFromRequest(r *http.Request) *store.TrialReservation {
	if t := trialFromRequest(r); t != nil {
		return t.reservation
	}
	return nil
}

// All attempts share this proof. It is cleared before dispatch, and only a
// genuine provider no-content terminal may re-enable a sequential retry.
func trialUnusedFromRequest(r *http.Request) *atomic.Bool {
	if t := trialFromRequest(r); t != nil {
		return &t.unusedConfirmed
	}
	return nil
}

// prepareBonsaiTrial marks eligible requests before ordinary money admission.
// The durable token reservation is taken after routing resolves the final build.
func (s *Server) prepareBonsaiTrial(w http.ResponseWriter, r *http.Request, model string, responses, media bool, policy *selfRoutePolicy, traits registry.RequestTraits) (*http.Request, bool) {
	kind, _ := r.Context().Value(ctxKeyAuthKind).(trial.AuthKind)
	if policy.enabled || responses || !s.bonsaiTrial.Matches(kind, r.URL.Path, model) {
		return r, true
	}
	if !s.bonsaiTrial.Enabled || s.bonsaiTrial.Validate() != nil || media {
		if s.trialOwnedFallback(policy, model, traits, media) {
			return r, true
		}
		s.writeTrialError(w, store.ErrTrialUnavailable)
		return r, false
	}
	if _, ok := store.As[store.TrialStore](s.store); !ok {
		s.writeTrialError(w, store.ErrTrialUnavailable)
		return r, false
	}
	t := &trialRequest{}
	t.unusedConfirmed.Store(true)
	return r.WithContext(context.WithValue(r.Context(), ctxKeyTrial, t)), true
}

func (s *Server) trialOwnedFallback(policy *selfRoutePolicy, model string, traits registry.RequestTraits, media bool) bool {
	if !policy.prefer {
		return false
	}
	_, capable := s.registry.OwnedProviderSummary(policy.ownerAccountID, model, traits, media)
	if capable == 0 {
		return false
	}
	policy.enabled, policy.prefer = true, false
	return true
}

// reserveBonsaiTrial uses the enforced model context as a conservative prompt
// bound. Unlike a bytes/4 estimate this remains safe for tools and templates.
// A smaller exact bound requires qualified tokenizer parity, not a heuristic.
func (s *Server) reserveBonsaiTrial(r *http.Request, model string, maxOutput int) error {
	t := trialFromRequest(r)
	if t == nil {
		return nil
	}
	if !s.bonsaiTrial.Matches(trial.AuthSession, r.URL.Path, model) {
		return store.ErrTrialUnavailable
	}
	rec, err := s.store.GetModelRegistryRecord(model)
	if err != nil || rec == nil || rec.MaxContextLength <= 0 || maxOutput <= 0 {
		return store.ErrTrialUnavailable
	}
	if rec.MaxOutputLength > 0 && maxOutput > rec.MaxOutputLength {
		return store.ErrTrialRequestTooLarge
	}
	bound, err := trial.ReservationTokens(int64(rec.MaxContextLength), int64(maxOutput), 1)
	if err != nil {
		return store.ErrTrialRequestTooLarge
	}
	in, out, configured := s.store.GetModelPrice("platform", model)
	rates := s.bonsaiTrial.Rates
	if !configured || in != rates.InputMicroUSDPerMillion || out != rates.OutputMicroUSDPerMillion {
		return store.ErrTrialUnavailable
	}
	snapshot := trialPriceSnapshot{Rates: rates}
	if u := auth.UserFromContext(r.Context()); u != nil && u.PlatformFeePercent != nil {
		fee := *u.PlatformFeePercent
		snapshot.FeePercent = &fee
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return store.ErrTrialUnavailable
	}
	ts, ok := store.As[store.TrialStore](s.store)
	if !ok {
		return store.ErrTrialUnavailable
	}
	reservation, err := ts.ReserveTrial(r.Context(), store.TrialReservation{
		ID: uuid.NewString(), AccountID: consumerKeyFromContext(r.Context()),
		CampaignID: s.bonsaiTrial.CampaignID, Model: model,
		LimitTokens: s.bonsaiTrial.TokenLimit, ReservedTokens: bound, PricingJSON: data,
	})
	if err != nil {
		return err
	}
	t.reservation = &reservation
	s.ddIncr("billing.bonsai_trial", []string{"outcome:reserved"})
	return nil
}

func (s *Server) writeTrialError(w http.ResponseWriter, err error) {
	status, code, message := http.StatusServiceUnavailable, trial.UnavailableCode, trial.UnavailableMessage
	switch {
	case errors.Is(err, store.ErrTrialExhausted):
		status, code, message = http.StatusPaymentRequired, trial.ExhaustedCode, trial.ExhaustedMessage
	case errors.Is(err, store.ErrTrialRequestTooLarge):
		status, code, message = http.StatusPaymentRequired, trial.RequestTooLargeCode, trial.RequestTooLargeMessage
	case errors.Is(err, store.ErrTrialBusy):
		status, code, message = http.StatusTooManyRequests, trial.BusyCode, trial.BusyMessage
		w.Header().Set("Retry-After", "1")
	}
	s.ddIncr("billing.bonsai_trial", []string{"outcome:" + code})
	writeJSON(w, status, errorResponse("insufficient_quota", message, withCode(code)))
}

func (s *Server) releaseTrialReservation(reservation *store.TrialReservation, confirmedUnused bool) bool {
	if reservation == nil {
		return false
	}
	ts, ok := store.As[store.TrialStore](s.store)
	if !ok {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := ts.ReleaseTrial(ctx, reservation.ID, confirmedUnused); err != nil {
		s.logger.Error("trial reservation release failed", "reservation_id", reservation.ID, "error", err)
		return false
	}
	return true
}

func (s *Server) finishTrialRequest(r *http.Request) {
	if t := trialFromRequest(r); t != nil && t.reservation != nil && !t.committed.Load() {
		s.releaseTrialReservation(t.reservation, t.unusedConfirmed.Load())
	}
}

func (s *Server) markTrialDispatched(pr *registry.PendingRequest, provider *registry.Provider) error {
	if pr.TrialReservation == nil {
		return nil
	}
	provider.Mu().Lock()
	account := provider.AccountID
	provider.Mu().Unlock()
	if account == "" {
		return store.ErrTrialUnavailable
	}
	var snapshot trialPriceSnapshot
	if json.Unmarshal(pr.TrialReservation.PricingJSON, &snapshot) != nil {
		return store.ErrTrialUnavailable
	}
	// Reject a conflicting provider price rather than underpaying that provider
	// or silently increasing the platform subsidy above the published rate.
	in, out, custom := s.store.GetModelPrice(providerPricingKeys(provider), pr.Model)
	if !trialServedByOwner(pr, provider) && custom && (in != snapshot.Rates.InputMicroUSDPerMillion || out != snapshot.Rates.OutputMicroUSDPerMillion) {
		return store.ErrTrialUnavailable
	}
	ts, ok := store.As[store.TrialStore](s.store)
	if !ok {
		return store.ErrTrialUnavailable
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Never let a later no-work terminal erase an earlier ambiguous attempt.
	// Only sequential attempts with positive prior no-content evidence retry.
	if proof := pr.TrialUnusedConfirmed; proof != nil && !proof.CompareAndSwap(true, false) {
		s.releaseTrialReservation(pr.TrialReservation, false)
		return store.ErrTrialUnavailable
	}
	return ts.MarkTrialDispatched(ctx, pr.TrialReservation.ID)
}
