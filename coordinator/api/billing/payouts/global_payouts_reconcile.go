package payouts

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) StartGlobalPayoutReconciler(ctx context.Context) {
	repo, ok := s.globalPayoutStore()
	if !ok {
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
			if _, err := repo.PruneExpiredGlobalPayoutQuotes(time.Now(), 1000); err != nil {
				s.logger.Warn("expired payout quote cleanup failed", "error", err)
			}
			if s.billing.GlobalPayouts() == nil {
				continue
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

func (s *Owner) HandleGlobalPayoutWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.GlobalPayouts() == nil || s.billing.GlobalPayoutsWebhookSecret() == "" {
		httpx.WriteJSON(w, 503, httpx.ErrorResponse("not_configured", "Payout event processing is unavailable."))
		return
	}
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "Invalid event."))
		return
	}
	verifier := billing.NewStripeConnect("", s.billing.GlobalPayoutsWebhookSecret(), "US", false, s.logger)
	if _, err = verifier.VerifyConnectWebhookSignature(payload, r.Header.Get("Stripe-Signature")); err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_signature", "Invalid event signature."))
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
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "Invalid event."))
		return
	}
	if !strings.Contains(event.Type, "outbound_payment.") {
		httpx.WriteJSON(w, 200, map[string]bool{"received": true})
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
		httpx.WriteJSON(w, 200, map[string]bool{"received": true})
		return
	}
	repo, ok := s.globalPayoutStore()
	if !ok {
		httpx.WriteJSON(w, 503, httpx.ErrorResponse("not_configured", "Payout storage unavailable."))
		return
	}
	p, err := repo.GetGlobalPayoutByExternalID(id)
	if errors.Is(err, store.ErrNotFound) {
		httpx. // A webhook can precede the create response. The persisted pending row is retried by the reconciler.
			WriteJSON(w, 200, map[string]bool{"received": true})
		return
	}
	if err == nil {
		err = s.syncGlobalPayout(r.Context(), p.ID)
	}
	if err != nil {
		httpx.WriteJSON(w, 500, httpx.ErrorResponse("reconcile_error", "Retry event delivery."))
		return
	}
	httpx.WriteJSON(w, 200, map[string]bool{"received": true})
}
