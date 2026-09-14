package readiness

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// Drain serves the admin drain endpoint. The API mounts it behind requireAuth;
// AuthorizeAdmin checks the current admin key or authenticated Privy admin.
// An empty body starts draining; {"draining":false} resumes admission.
func (s *Controller) Drain(w http.ResponseWriter, r *http.Request) {
	if !s.deps.AuthorizeAdmin(w, r) {
		return
	}

	// Decode any potentially present body, including unknown-length/chunked
	// requests. An empty body keeps the default; explicit false resumes admission.
	draining := true
	if r.Body != nil && r.ContentLength != 0 {
		var payload struct {
			Draining *bool `json:"draining"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, s.deps.MaxBodyBytes)
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
			var maxErr *http.MaxBytesError
			if errors.As(err, &maxErr) {
				httpresponse.WriteJSON(w, http.StatusRequestEntityTooLarge,
					httpresponse.ErrorBody("invalid_request_error", "request body too large"))
				return
			}
			httpresponse.WriteJSON(w, http.StatusBadRequest,
				httpresponse.ErrorBody("invalid_request_error", "invalid JSON"))
			return
		}
		if payload.Draining != nil {
			draining = *payload.Draining
		}
	}

	s.SetDraining(draining)
	s.deps.Logger().Info("coordinator drain state changed",
		"draining", draining,
		"inflight", s.Inflight(),
	)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"draining": draining,
		"inflight": s.Inflight(),
	})
}
