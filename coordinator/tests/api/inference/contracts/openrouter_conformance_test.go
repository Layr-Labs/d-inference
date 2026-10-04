package inference_test

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/conformance"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

// Keep only the composition bindings here. All scenarios, fixtures and
// observers live in tests/internal/conformance. No production API is exported
// for testing: the server is the real composed runtime, and the ledger and
// reservation controller are the constructor dependencies this fixture retains.
func conformanceSuite() conformance.Suite {
	return conformance.Suite{
		NewServer: func(t *testing.T, st *memory.MemoryStore, holds bool, account string) conformance.Backend {
			t.Helper()
			logger := quietLogger()
			reg := registry.New(logger)
			ledger := payments.NewLedger(st)
			serviceHolds := &reservations.Controller{}
			srv := api.NewRuntime(api.RuntimeDependencies{
				Registry: reg, Store: st, Ledger: ledger, ReadCache: readcache.New(), Logger: logger,
				InferenceReservations: serviceHolds,
			}, api.ServerConfig{ServiceReservations: holds, FirstContentSLAAccounts: []string{account}, FirstContentDeadlineBase: 3 * time.Second}).Server
			srv.SetChallengeInterval(time.Hour)
			reg.SetQueue(registry.NewRequestQueue(10, 100*time.Millisecond))
			srv.SetBilling(billing.NewService(st, ledger, logger, billing.Config{MockMode: true}))
			return conformance.Backend{Server: srv, Registry: reg, Outstanding: func(account string) int64 {
				if !holds {
					// A disabled manager records nothing, so nothing can be outstanding.
					return 0
				}
				return outstandingServiceHold(t, serviceHolds, st, account)
			}}
		},
		ModelR2Prefix: testkit.ModelPrefix, NewManifest: conformanceManifest,
		NewProviderKey: testkit.PublicKeyB64,
		ProviderPrivateKey: func(t *testing.T, key string) *[32]byte {
			t.Helper()
			value, ok := testkit.ProviderKeys.Load(key)
			if !ok {
				t.Fatal("missing fixture provider key")
			}
			private := value.(testkit.ProviderKeyPair).Private
			return &private
		},
		DeleteProviderKey: func(key string) { testkit.ProviderKeys.Delete(key) },
		EncryptChunk: func(t *testing.T, request protocol.InferenceRequestMessage, providerPublicKey, sse string) protocol.InferenceResponseChunkMessage {
			t.Helper()
			return testkit.EncryptedChunk(t, request, providerPublicKey, sse)
		},
		PrivacyCapabilities: testkit.PrivacyCaps,
	}
}

// serviceHoldProbeModel only labels the probe's reservation metrics.
const serviceHoldProbeModel = "conformance-hold-probe"

// outstandingServiceHold measures a service account's unreleased in-memory
// hold at the reservation controller's own admission boundary. The controller
// keeps the per-account sum private and admits a service reservation only while
// the ledger balance minus that sum covers it, so the largest admitted amount
// is the unheld balance. Every admitted probe is released before the next one;
// the fixture issues no concurrent request admission while it measures.
func outstandingServiceHold(t *testing.T, holds *reservations.Controller, st store.Store, account string) int64 {
	t.Helper()
	balance := st.GetBalance(account)
	if balance <= 0 {
		t.Fatalf("service hold probe needs a positive balance, got %d", balance)
	}
	admits := func(amount int64) bool {
		serviceMode, err := holds.ReserveInitial(account, serviceHoldProbeModel, amount)
		if !serviceMode {
			if err == nil {
				// Ledger mode debited the probe; refund it before failing.
				holds.ReleaseInitial(account, serviceHoldProbeModel, amount, false)
			}
			t.Fatalf("service hold probe for %q did not use the in-memory hold (err=%v)", account, err)
		}
		if err != nil {
			return false
		}
		holds.ReleaseInitial(account, serviceHoldProbeModel, amount, true)
		return true
	}
	// Amounts 1..unheld are admitted and every larger amount is refused.
	unheld := int64(sort.Search(int(balance), func(i int) bool { return !admits(int64(i) + 1) }))
	return balance - unheld
}

// conformanceManifest is independent of the production address builder and
// manifest hash aggregator, like the catalog contract fixtures.
func conformanceManifest() *store.ModelManifest {
	files := []store.ManifestFile{{Path: "config.json", SizeBytes: 123, SHA256: testkit.ModelHash, Role: "config"}}
	return &store.ModelManifest{
		SchemaVersion:   1,
		ModelID:         "mlx-community/test",
		Version:         "v1",
		R2Prefix:        testkit.ModelPrefix("mlx-community/test", "v1"),
		AggregateSHA256: fmt.Sprintf("%x", sha256.Sum256(bytes.Repeat([]byte{0xaa}, 32))),
		TotalSizeBytes:  123,
		FileCount:       1,
		Files:           files,
		CreatedAt:       time.Now(),
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
