package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/conformance"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Keep only the package-private bindings here. All scenarios, fixtures and
// observers live in conformance/. No production API is exported for testing.
func conformanceSuite() conformance.Suite {
	return conformance.Suite{
		NewServer: func(t *testing.T, st *store.MemoryStore, holds bool, account string) conformance.Backend {
			t.Helper()
			logger := quietLogger()
			reg := registry.New(logger)
			srv := NewServer(reg, st, ServerConfig{ServiceReservations: holds, FirstContentSLAAccounts: []string{account}, FirstContentDeadlineBase: 3 * time.Second}, logger)
			srv.challengeInterval = time.Hour
			reg.SetQueue(registry.NewRequestQueue(10, 100*time.Millisecond))
			srv.SetBilling(billing.NewService(st, srv.ledger, logger, billing.Config{MockMode: true}))
			return conformance.Backend{Server: srv, Registry: reg, Outstanding: func(account string) int64 {
				m := srv.serviceReservations
				m.mu.Lock()
				defer m.mu.Unlock()
				return m.outstanding[account]
			}}
		},
		ModelR2Prefix: modelR2Prefix, NewManifest: validTestManifest,
		NewProviderKey: testPublicKeyB64,
		ProviderPrivateKey: func(t *testing.T, key string) *[32]byte {
			t.Helper()
			value, ok := testProviderKeys.Load(key)
			if !ok {
				t.Fatal("missing fixture provider key")
			}
			private := value.(testProviderKeyPair).private
			return &private
		},
		DeleteProviderKey: func(key string) { testProviderKeys.Delete(key) },
		EncryptChunk:      testEncryptedChunk, PrivacyCapabilities: testPrivacyCaps,
	}
}

func TestOpenRouterConformanceAuth(t *testing.T) { conformanceSuite().TestOpenRouterConformanceAuth(t) }
func TestOpenRouterConformanceFeed(t *testing.T) { conformanceSuite().TestOpenRouterConformanceFeed(t) }
func TestOpenRouterConformanceChat(t *testing.T) { conformanceSuite().TestOpenRouterConformanceChat(t) }
func TestOpenRouterConformanceAccountSLA(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceAccountSLA(t)
}
func TestOpenRouterConformanceDrain(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceDrain(t)
}
func TestOpenRouterConformanceRetry(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceRetry(t)
}
func TestOpenRouterConformancePostContentFailure(t *testing.T) {
	conformanceSuite().TestOpenRouterConformancePostContentFailure(t)
}
func TestOpenRouterConformanceClientError(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceClientError(t)
}
func TestOpenRouterConformanceCancellation(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceCancellation(t)
}
func TestOpenRouterConformanceCompletionFirst(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceCompletionFirst(t)
}
func TestOpenRouterConformanceTools(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceTools(t)
}
func TestOpenRouterConformanceObserver(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceObserver(t)
}
func TestOpenRouterConformanceIncidentEnvelope(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceIncidentEnvelope(t)
}
func TestOpenRouterConformanceIncidentRefusal(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceIncidentRefusal(t)
}
func TestOpenRouterConformanceIncidentProvenance(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceIncidentProvenance(t)
}
func TestOpenRouterConformanceReadinessFeed(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceReadinessFeed(t)
}
func TestOpenRouterConformanceReadinessCapabilities(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceReadinessCapabilities(t)
}
func TestOpenRouterConformanceScenario(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceScenario(t)
}
func TestOpenRouterConformanceScenarioFragmentation(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceScenarioFragmentation(t)
}
func TestOpenRouterConformanceScenarioBounds(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceScenarioBounds(t)
}
func TestOpenRouterConformanceScenarioChoiceShape(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceScenarioChoiceShape(t)
}
func TestOpenRouterConformanceTransport(t *testing.T) {
	conformanceSuite().TestOpenRouterConformanceTransport(t)
}
