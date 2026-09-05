package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// syncGlobalPayout always reads Stripe's current state rather than applying
// potentially duplicated/out-of-order webhook state directly to the ledger.
func (s *Server) syncGlobalPayout(ctx context.Context, id string) error {
	repo, ok := s.globalPayoutStore()
	if !ok || s.billing.GlobalPayouts() == nil {
		return errors.New("Global Payouts unavailable")
	}
	claimed, err := repo.ClaimGlobalPayout(id, time.Now())
	if err != nil {
		return err
	}
	if !claimed {
		p, e := repo.GetGlobalPayout(id)
		if e != nil {
			return e
		}
		if p.Refunded {
			return nil
		}
		return errors.New("payout reconciliation is already in progress")
	}
	p, err := repo.GetGlobalPayout(id)
	if err != nil {
		return err
	}
	var request globalpayouts.PaymentRequest
	if err = json.Unmarshal(p.Request, &request); err != nil {
		return err
	}
	if request.From["financial_account"] != s.billing.GlobalPayouts().FinancialAccount {
		return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{FailureCode: "funding_account_changed"}, time.Now())
	}
	var remote *globalpayouts.Payment
	client := s.billing.GlobalPayouts()
	if p.ExternalID != "" {
		remote, err = client.Payment(ctx, p.ExternalID)
	} else {
		// Never resubmit after the retention horizon of the idempotency key.
		// Preserve the debit and surface the exception for manual reconciliation.
		if time.Since(p.SubmittedAt) > 12*time.Hour {
			s.logger.Error("global payout outcome requires manual reconciliation", "withdrawal_id", p.ID)
			return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{FailureCode: "confirmation_pending"}, time.Now())
		}
		remote, err = client.Send(ctx, p.Request, "gp-withdraw-"+p.ID)
	}
	if err != nil {
		result := store.GlobalPayoutResult{FailureCode: "confirmation_pending"}
		var apiErr *globalpayouts.Error
		if p.ExternalID == "" && p.DispatchAttempts == 1 && errors.As(err, &apiErr) && apiErr.Definitive() {
			result.Status = "failed"
			result.FailureCode = apiErr.Code
		}
		if persistErr := repo.ApplyGlobalPayout(id, result, time.Now()); persistErr != nil {
			return persistErr
		}
		return err
	}
	if err = remote.Validate(request); err != nil {
		return err
	}
	return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExternalID: remote.ID, Status: remote.Status, FailureCode: remote.StatusDetails[remote.Status].Reason, DestinationAmount: remote.To.Credited.Value, Currency: remote.To.Credited.Currency, Arrival: remote.ExpectedArrivalDate}, time.Now())
}

func (s *Server) StartGlobalPayoutReconciler(ctx context.Context) {
	repo, ok := s.globalPayoutStore()
	if !ok || s.billing.GlobalPayouts() == nil {
		return
	}
	saferun.Go(s.logger, "api.globalPayoutReconciler", func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			rows, err := repo.ListGlobalPayoutsToReconcile(time.Now(), 200)
			if err != nil {
				s.logger.Error("global payout reconciliation scan failed", "error", err)
				continue
			}
			for _, p := range rows {
				if ctx.Err() != nil {
					return
				}
				if err = s.syncGlobalPayout(ctx, p.ID); err != nil {
					s.logger.Warn("global payout reconciliation failed", "withdrawal_id", p.ID, "error", err)
				}
			}
		}
	})
}

func (s *Server) handleGlobalPayoutWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.GlobalPayouts() == nil || s.billing.GlobalPayoutsWebhookSecret() == "" {
		writeJSON(w, 503, errorResponse("not_configured", "Payout event processing is unavailable."))
		return
	}
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", "Invalid event."))
		return
	}
	verifier := billing.NewStripeConnect("", s.billing.GlobalPayoutsWebhookSecret(), "US", false, s.logger)
	if _, err = verifier.VerifyConnectWebhookSignature(payload, r.Header.Get("Stripe-Signature")); err != nil {
		writeJSON(w, 400, errorResponse("invalid_signature", "Invalid event signature."))
		return
	}
	var event struct {
		Type          string `json:"type"`
		RelatedObject struct {
			ID string `json:"id"`
		} `json:"related_object"`
		Data struct {
			Object struct {
				ID string `json:"id"`
			} `json:"object"`
			RelatedObject struct {
				ID string `json:"id"`
			} `json:"related_object"`
		} `json:"data"`
	}
	if json.Unmarshal(payload, &event) != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", "Invalid event."))
		return
	}
	if !strings.Contains(event.Type, "outbound_payment.") {
		writeJSON(w, 200, map[string]bool{"received": true})
		return
	}
	id := event.Data.Object.ID
	if id == "" {
		id = event.RelatedObject.ID
	}
	if id == "" {
		id = event.Data.RelatedObject.ID
	}
	if !strings.HasPrefix(id, "obp_") {
		writeJSON(w, 200, map[string]bool{"received": true})
		return
	}
	repo, ok := s.globalPayoutStore()
	if !ok {
		writeJSON(w, 503, errorResponse("not_configured", "Payout storage unavailable."))
		return
	}
	p, err := repo.GetGlobalPayoutByExternalID(id)
	if errors.Is(err, store.ErrNotFound) { // A webhook can precede the create response. The persisted pending row is retried by the reconciler.
		writeJSON(w, 200, map[string]bool{"received": true})
		return
	}
	if err == nil {
		err = s.syncGlobalPayout(r.Context(), p.ID)
	}
	if err != nil {
		writeJSON(w, 500, errorResponse("reconcile_error", "Retry event delivery."))
		return
	}
	writeJSON(w, 200, map[string]bool{"received": true})
}
