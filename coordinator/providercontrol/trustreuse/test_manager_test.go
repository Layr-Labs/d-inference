package trustreuse

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/crypto/nacl/box"
	"io"
	"log/slog"
	"strings"
	"time"
)

// testManager retains the original store/registry fixture around the real
// owner. Only API-owned callbacks are inert here; actual route, signed-challenge
// and MDM callback integration assertions remain in coordinator/api.
type testManager struct {
	*Manager
	registry  *registry.Registry
	store     store.Store
	mdmClient *mdm.Client
}

func newTestManager(reg *registry.Registry, st store.Store, cfg Config, logger *slog.Logger) *testManager {
	fixture := &testManager{registry: reg, store: st}
	fixture.Manager = New(cfg, Dependencies{
		Registry: reg, Logger: logger, MDMConfigured: func() bool { return fixture.mdmClient != nil },
		NormalizeHash:  normalizeHashForTest,
		SendStatus:     func(*registry.Provider, registry.TrustLevel, string, string) {},
		RecordDecision: func(Decision, Reason) {}, AfterCoverageSweep: func() {},
	})
	// These fixtures drive coverage explicitly with their own clock. The
	// periodic worker must not race those deterministic clock mutations.
	fixture.StopCoverage()
	return fixture
}
func (s *testManager) SeedTrustReuseCache(ctx context.Context) error { return s.Seed(ctx, s.store) }
func (s *testManager) Close() {
	s.StopCoverage()
	s.FinalCoverageSweep()
	s.StopReplay()
	s.ReleaseAuthority()
}
func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }
func testPublicKeyB64() string {
	pub, _, err := box.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(pub[:])
}
func waitForCond(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}
func normalizeHashForTest(value, field string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if len(value) != sha256.Size*2 {
		return "", fmt.Errorf("%s must be a 64-character SHA-256 hex digest", field)
	}
	if _, err := hex.DecodeString(value); err != nil {
		return "", fmt.Errorf("%s must be a valid SHA-256 hex digest", field)
	}
	return value, nil
}
