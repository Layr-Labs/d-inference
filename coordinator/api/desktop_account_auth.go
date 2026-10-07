package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const desktopAccountPurpose = "desktop_account"
const desktopAccountCodePrefix = "desktop-account-"
const desktopAccountTokenPrefix = "darkbloom-at-"
const desktopAccountLifetime = 30 * 24 * time.Hour

// Account sessions reuse the hashed-token store, but have a separate scope and expiry.
// Only the three read-only dashboard routes opt into this middleware.
func (s *Server) desktopAccountToken(r *http.Request) (*store.ProviderToken, error) {
	token := extractBearerToken(r)
	if !strings.HasPrefix(token, desktopAccountTokenPrefix) {
		return nil, http.ErrNoCookie
	}
	pt, err := s.store.GetProviderToken(token)
	if err != nil || pt == nil || !pt.Active || !strings.HasPrefix(pt.Label, desktopAccountCodePrefix) || pt.CreatedAt.IsZero() || !time.Now().Before(pt.CreatedAt.Add(desktopAccountLifetime)) {
		return nil, http.ErrNoCookie
	}
	return pt, nil
}

func (s *Server) requireAccountRead(fallback http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(extractBearerToken(r), desktopAccountTokenPrefix) {
			fallback(w, r)
			return
		}
		pt, err := s.desktopAccountToken(r)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "account session expired or revoked"))
			return
		}
		user, err := s.store.GetUserByAccountID(pt.AccountID)
		if err != nil || user == nil {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "account unavailable"))
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyConsumer, pt.AccountID)
		ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
		// The fallback middleware is deliberately bypassed only after read-only scope validation.
		switch r.URL.Path {
		case "/v1/me/providers":
			s.handleMyProviders(w, r.WithContext(ctx))
		case "/v1/me/summary":
			s.handleMySummary(w, r.WithContext(ctx))
		case "/v1/provider/account-earnings":
			s.handleAccountEarnings(w, r.WithContext(ctx))
		default:
			writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "read-only account session"))
		}
	}
}

func (s *Server) issueDesktopAccountToken(w http.ResponseWriter, dc *store.DeviceCode) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		writeJSON(w, 500, errorResponse("server_error", "failed to create session"))
		return
	}
	token := desktopAccountTokenPrefix + hex.EncodeToString(b)
	now := time.Now()
	pt := &store.ProviderToken{TokenHash: sha256Hash(token), AccountID: dc.AccountID, Label: desktopAccountCodePrefix + dc.UserCode, Active: true, CreatedAt: now}
	if err := s.store.CreateProviderToken(pt); err != nil {
		writeJSON(w, 500, errorResponse("server_error", "failed to save session"))
		return
	}
	if err := s.store.ConsumeDeviceCode(dc.DeviceCode); err != nil {
		_ = s.store.RevokeProviderToken(token)
		writeJSON(w, http.StatusGone, errorResponse("invalid_grant", "account grant already exchanged or expired"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "authorized", "purpose": desktopAccountPurpose, "token": token, "account_id": dc.AccountID, "expires_in": int(desktopAccountLifetime.Seconds())})
}

func (s *Server) revokeDesktopAccountToken(w http.ResponseWriter, r *http.Request) {
	if _, err := s.desktopAccountToken(r); err != nil {
		writeJSON(w, 401, errorResponse("authentication_error", "invalid account session"))
		return
	}
	if err := s.store.RevokeProviderToken(extractBearerToken(r)); err != nil {
		writeJSON(w, 500, errorResponse("server_error", "failed to revoke account session"))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
