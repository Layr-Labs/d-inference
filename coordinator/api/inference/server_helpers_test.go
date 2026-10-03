package inference

import (
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// quietLogger returns a logger that discards everything — for tests that
// exercise noisy failure paths.
func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// testBillingServer creates a Server with mock billing enabled and returns it
// along with the underlying store. Used by earnings, payout, and other billing tests.
func testBillingServer(t *testing.T) (*Owner, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)

	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{
		MockMode: true,
	})
	testComposition(srv).BindBilling(billingSvc)
	return srv, st
}

func testServer(t *testing.T) (*Owner, *memory.MemoryStore) {
	return testServerWithConfig(t, TestServerConfig{})
}

func testServerWithConfig(t *testing.T, cfg TestServerConfig) (*Owner, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, cfg, logger)
	t.Cleanup(srv.Close)
	return srv, st
}

// billingTestServer creates a test server with billing enabled in mock mode.
// Returns the server, underlying store, and ledger for assertion access.
// testConsumerID is the ledger identity the coordinator now derives for the
// unlinked "test-key" bearer (see store.LegacyAccountID). Requests still send
// the raw "test-key" token; balances and usage are tracked under this hashed,
// non-secret identity so the raw key never reaches the ledger or logs.
var testConsumerID = store.LegacyAccountID("test-key")
