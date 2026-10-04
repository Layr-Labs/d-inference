package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/conformance"
)

// Keep only the composition bindings here. All scenarios, fixtures and
// observers live in tests/internal/conformance. No production API is exported
// for testing: the server is the real composed runtime, and the ledger and
// reservation controller are the constructor dependencies this fixture retains.
func conformanceSuite() conformance.Suite {
	return conformance.Suite{
		NewServer: func(t *testing.T, st *memory.MemoryStore, holds bool, slaAccount string) conformance.Backend {
			t.Helper()
			logger := quietLogger()
			reg := registry.New(logger)
			ledger := payments.NewLedger(st)
			serviceHolds := &reservations.Controller{}
			srv := api.NewRuntime(api.RuntimeDependencies{
				Registry: reg, Store: st, Ledger: ledger, ReadCache: readcache.New(), Logger: logger,
				InferenceReservations: serviceHolds,
			}, api.ServerConfig{ServiceReservations: holds, FirstContentSLAAccounts: []string{slaAccount}, FirstContentDeadlineBase: 3 * time.Second}).Server
			srv.SetChallengeInterval(time.Hour)
			reg.SetQueue(registry.NewRequestQueue(10, 100*time.Millisecond))
			srv.SetBilling(billing.NewService(st, ledger, logger, billing.Config{MockMode: true}))
			return conformance.Backend{Server: srv, Registry: reg, Outstanding: func(account string) int64 {
				if !holds {
					// A disabled manager records nothing, so nothing can be outstanding.
					return 0
				}
				return conformance.OutstandingServiceHold(t, serviceHolds, st, account)
			}}
		},
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
