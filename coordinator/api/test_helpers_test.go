package api

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// quietLogger returns a logger that discards everything — for tests that
// exercise noisy failure paths.
func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// testBillingServer creates a Server with mock billing enabled and returns it
// along with the underlying store. Used by earnings, payout, and other billing tests.
func testBillingServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{
		MockMode: true,
	})
	srv.SetBilling(billingSvc)
	return srv, st
}

// withPrivyUser returns a request with the given user set in context, simulating
// Privy authentication without requiring JWT verification.
func withPrivyUser(r *http.Request, user *store.User) *http.Request {
	ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return r.WithContext(ctx)
}

func testServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	return srv, st
}

func newAuthRequest(t *testing.T, ctx context.Context, url, body, key string) *http.Request {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		t.Fatalf("create authenticated request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	return req
}

func waitFor(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	if cond() {
		return
	}

	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	for {
		select {
		case <-ticker.C:
			if cond() {
				return
			}
		case <-timer.C:
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

// billingTestServer creates a test server with billing enabled in mock mode.
// Returns the server, underlying store, and ledger for assertion access.
// testConsumerID is the ledger identity the coordinator now derives for the
// unlinked "test-key" bearer (see store.LegacyAccountID). Requests still send
// the raw "test-key" token; balances and usage are tracked under this hashed,
// non-secret identity so the raw key never reaches the ledger or logs.
var testConsumerID = store.LegacyAccountID("test-key")
