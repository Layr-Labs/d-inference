package api

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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

// testWithdrawServer is an alias for testBillingServer for backward compatibility.
func testWithdrawServer(t *testing.T) (*Server, *store.MemoryStore) {
	return testBillingServer(t)
}

// withPrivyUser returns a request with the given user set in context, simulating
// Privy authentication without requiring JWT verification.
func withPrivyUser(r *http.Request, user *store.User) *http.Request {
	ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return r.WithContext(ctx)
}
