package inference_test

import (
	"log/slog"
	"net/http"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backoff"
	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/chunkkeys"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerhealth"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/scangate"
	latesettlement "github.com/eigeninference/d-inference/coordinator/internal/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type TestServerConfig = api.ServerConfig
type ExactCacheStatus = inference.ExactCacheStatus

// Keep the real composition alive alongside its inference owner. No methods
// are attached to production types, and both paths use the same request owner.
type serverFixture struct {
	*inference.Owner
	server             *api.Server
	registry           *registry.Registry
	store              store.Store
	ledger             *payments.Ledger
	billing            *billing.Service
	observation        *observation.Owner
	health             providerhealth.Policy
	late               *latesettlement.Controller
	cancels            *cancellation.Controller
	scanGate           *scangate.Gate
	backoff            *backoff.Policy
	reservations       *reservations.Controller
	chunkKeys          *chunkkeys.Cache
	firstContentPolicy *firstcontent.AccountPolicy
	hedgeGov           *hedge.Governor
	logger             *slog.Logger
}

func newComposedServer(reg *registry.Registry, st store.Store, cfg TestServerConfig, logger *slog.Logger) *serverFixture {
	ledger := payments.NewLedger(st)
	late := &latesettlement.Controller{Holder: latesettlement.New()}
	cancels := &cancellation.Controller{Tracker: cancellation.NewTracker(nil)}
	scans := scangate.New(inference.DefaultRoutingConcurrency())
	retryBackoff := &backoff.Policy{}
	holds := &reservations.Controller{}
	keys := &chunkkeys.Cache{}
	accountPolicy := &firstcontent.AccountPolicy{}
	governor := hedge.NewGovernor()
	runtime := api.NewRuntime(api.RuntimeDependencies{
		Registry: reg, Store: st, Ledger: ledger, ReadCache: readcache.New(), Logger: logger,
		InferenceSettlement:         late,
		InferenceCancellation:       cancels,
		InferenceScanGate:           scans,
		InferenceBackoff:            retryBackoff,
		InferenceReservations:       holds,
		InferenceChunkKeys:          keys,
		InferenceFirstContentPolicy: accountPolicy,
		InferenceHedgeGovernor:      governor,
	}, cfg)
	srv := runtime.Server
	return &serverFixture{
		Owner: srv.Inference(), server: srv, registry: reg, store: st, ledger: ledger, observation: runtime.Observation,
		health:             providerhealth.Policy{Registry: reg, Store: st, Observation: runtime.Observation, Logger: logger},
		late:               late,
		cancels:            cancels,
		scanGate:           scans,
		backoff:            retryBackoff,
		reservations:       holds,
		chunkKeys:          keys,
		firstContentPolicy: accountPolicy,
		hedgeGov:           governor,
		logger:             logger,
	}
}

func (s *serverFixture) Handler() http.Handler { return s.server.Handler() }
func (s *serverFixture) Close()                { s.server.Close() }

func (s *serverFixture) NewMetrics() *infermetrics.Reporter {
	if s == nil {
		return nil
	}
	return &infermetrics.Reporter{Observation: s.observation, Logger: s.logger}
}

func testServerWithConfig(t *testing.T, cfg TestServerConfig) (*serverFixture, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	f := newComposedServer(registry.New(logger), st, cfg, logger)
	t.Cleanup(f.Close)
	return f, st
}

func testServer(t *testing.T) (*serverFixture, *memory.MemoryStore) {
	t.Helper()
	return testServerWithConfig(t, TestServerConfig{})
}

var testConsumerID = store.LegacyAccountID("test-key")

func (s *serverFixture) bindBilling(service *billing.Service) {
	s.billing = service
	s.server.SetBilling(service)
}

const (
	envQueueBeforeShed         = "EIGENINFERENCE_QUEUE_BEFORE_SHED"
	envColdDispatch            = "EIGENINFERENCE_COLD_DISPATCH"
	metricTypedTerminal        = "inference.typed_terminal"
	metricUnknownTerminalCause = "inference.typed_terminal_unknown_cause"
	phaseBeforeFirstToken      = "before_first_token"
	phaseAfterCommit           = "after_commit"
	deadlineBucketUnknown      = "unknown"
	metricTimingSegmentPrefix  = "inference.timing."
)
