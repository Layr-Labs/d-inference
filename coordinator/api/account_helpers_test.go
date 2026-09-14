package api

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func newKeyTestServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	return srv, st
}

// reqWithUser builds a request whose context carries an authenticated user,
// simulating what requirePrivyAuth installs (so we can unit-test the handlers
// without minting a real Privy JWT).
func reqWithUser(method, target, body, accountID string) *http.Request {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, target, nil)
	} else {
		r = httptest.NewRequest(method, target, strings.NewReader(body))
	}
	ctx := context.WithValue(r.Context(), auth.CtxKeyUser, &store.User{AccountID: accountID})
	ctx = requestcontext.WithAccountID(ctx, accountID)
	return r.WithContext(ctx)
}

func withUser(ctx context.Context, accountID, email string) context.Context {
	return context.WithValue(ctx, auth.CtxKeyUser, &store.User{
		AccountID: accountID,
		Email:     email,
	})
}
