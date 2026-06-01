// Package registry manages the set of connected provider agents, their
// capabilities, and routes inference requests to appropriate providers.
//
// The registry is the coordinator's in-memory view of the provider fleet.
// It tracks each provider's hardware, available models, attestation status,
// trust level, and operational state (online/serving/offline/untrusted).
//
// Routing uses round-robin among idle providers that serve the requested
// model. Providers that fail too many attestation challenges are marked
// as untrusted and excluded from routing. Stale providers (no heartbeat
// within the timeout) are evicted by a background goroutine.
//
// Trust levels:
//   - none: Provider did not include an attestation blob
//   - self_signed: Provider's attestation was signed by its own SE key
//   - hardware: MDA certificate chain verified (future, requires Apple
//     Business Manager enrollment)
package registry

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Registry holds all connected providers and provides routing.
type Registry struct {
	mu        sync.RWMutex
	providers map[string]*Provider

	queue *RequestQueue

	MinTrustLevel TrustLevel

	modelCatalog map[string]CatalogEntry

	store store.Store

	tpsRegistry *TPSRegistry

	logger *slog.Logger

	onlineCount      atomic.Int64
	modelProviders   map[string]*atomic.Int64
	modelProvidersMu sync.Mutex

	// pendingModelLoads tracks provider-model pairs that have been sent a
	// load_model command and are awaiting completion. Prevents duplicate
	// sends across heartbeat cycles.
	pendingModelLoads map[string]time.Time // key: "providerID:modelID"
}

const pendingModelLoadTTL = 2 * time.Minute

type modelLoadAction struct {
	providerID string
	modelID    string
}

// New creates a new Registry.
func New(logger *slog.Logger) *Registry {
	return &Registry{
		providers:         make(map[string]*Provider),
		queue:             NewRequestQueue(10, 120*time.Second),
		MinTrustLevel:     TrustHardware,
		tpsRegistry:       NewTPSRegistry(),
		modelProviders:    make(map[string]*atomic.Int64),
		pendingModelLoads: make(map[string]time.Time),
		logger:            logger,
	}
}

// SetStore configures the persistence store for the registry.
// When set, provider state and reputation are persisted to the store.
func (r *Registry) SetStore(st store.Store) {
	r.store = st
}

// Queue returns the registry's request queue.
func (r *Registry) Queue() *RequestQueue {
	return r.queue
}

// SetQueue replaces the registry's request queue. This is useful for tests
// that need a larger queue capacity than the default.
func (r *Registry) SetQueue(q *RequestQueue) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.queue = q
}
