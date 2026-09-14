package billing

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller) GlobalPayoutWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().GlobalPayouts() == nil || s.billing().GlobalPayoutsWebhookSecret() == "" {
		httpresponse.WriteJSON(w, 503, httpresponse.ErrorBody("not_configured", "Payout event processing is unavailable."))
		return
	}
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", "Invalid event."))
		return
	}
	verifier := billingservice.NewStripeConnect("", s.billing().GlobalPayoutsWebhookSecret(), "US", false, s.logger)
	if _, err = verifier.VerifyConnectWebhookSignature(payload, r.Header.Get("Stripe-Signature")); err != nil {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_signature", "Invalid event signature."))
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
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", "Invalid event."))
		return
	}
	if !strings.Contains(event.Type, "outbound_payment.") {
		httpresponse.WriteJSON(w, 200, map[string]bool{"received": true})
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
		httpresponse.WriteJSON(w, 200, map[string]bool{"received": true})
		return
	}
	repo, ok := s.globalPayoutStore()
	if !ok {
		httpresponse.WriteJSON(w, 503, httpresponse.ErrorBody("not_configured", "Payout storage unavailable."))
		return
	}
	p, err := repo.GetGlobalPayoutByExternalID(id)
	if errors.Is(err, store.ErrNotFound) { // A webhook can precede the create response. The persisted pending row is retried by the reconciler.
		httpresponse.WriteJSON(w, 200, map[string]bool{"received": true})
		return
	}
	if err == nil {
		err = s.syncGlobalPayout(r.Context(), p.ID)
	}
	if err != nil {
		httpresponse.WriteJSON(w, 500, httpresponse.ErrorBody("reconcile_error", "Retry event delivery."))
		return
	}
	httpresponse.WriteJSON(w, 200, map[string]bool{"received": true})
}
