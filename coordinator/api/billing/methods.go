package billing

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

func (s *Controller) BillingMethods(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil {
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"methods": []any{}})
		return
	}
	methods := s.billing().SupportedMethods()
	resp := map[string]any{"methods": methods}
	if s.billing().Referral() != nil {
		resp["referral"] = map[string]any{
			"enabled":       true,
			"share_percent": s.billing().Referral().SharePercent(),
		}
	}
	httpresponse.WriteJSON(w, http.StatusOK, resp)
}
