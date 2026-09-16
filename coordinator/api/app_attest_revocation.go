package api

import (
	"context"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
	"time"
)

func (s *Server) handleAdminAppAttestRevoke(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	var body struct {
		KeyID     string `json:"key_id"`
		AccountID string `json:"account_id"`
		Reason    string `json:"reason"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(&body); err != nil || len(body.KeyID) == 0 || len(body.KeyID) > 64 || len(body.AccountID) == 0 || len(body.AccountID) > 256 || len(body.Reason) == 0 || len(body.Reason) > 128 {
		http.Error(w, "invalid revocation", http.StatusBadRequest)
		return
	}
	st, ok := store.As[store.AppAttestReadinessStore](s.store)
	if !ok {
		http.Error(w, "revocation storage unavailable", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	changed, err := st.RevokeAppAttestKey(ctx, body.KeyID, body.AccountID, body.Reason)
	if err != nil {
		http.Error(w, "revocation storage unavailable", http.StatusServiceUnavailable)
		return
	}
	// An idempotent repeat still fences local leases. Verify account ownership
	// even when the INSERT did not create a row; never revoke an unrelated key.
	keys, ok := store.As[store.AppAttestShadowStore](s.store)
	if !ok {
		http.Error(w, "credential storage unavailable", http.StatusServiceUnavailable)
		return
	}
	key, err := keys.GetAppAttestShadowKey(ctx, body.KeyID)
	if err != nil {
		http.Error(w, "credential storage unavailable", http.StatusServiceUnavailable)
		return
	}
	if key == nil || key.AccountID != body.AccountID {
		http.Error(w, "credential not found", http.StatusNotFound)
		return
	}
	affected := s.registry.RevokeAppAttestCredential(body.KeyID)
	if s.appAttestAuthorizer != nil {
		a := s.appAttestAuthorizer
		a.mu.Lock()
		for p, record := range a.current {
			if record.evidence.Binding.Credential == body.KeyID {
				delete(a.current, p)
			}
		}
		a.mu.Unlock()
	}
	for _, id := range affected {
		s.sendAppAttestAuthorizationStatus(s.registry.GetProvider(id))
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"revoked": true, "changed": changed, "max_propagation_seconds": int(appAttestRevocationFreshness.Seconds())})
}
