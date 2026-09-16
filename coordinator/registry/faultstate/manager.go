package faultstate

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// Manager owns the coupled session/identity index and all fault history. A
// Connection is opaque to the owner; registry binds its exact Provider pointer.
// Callers retain their live registry/provider locks around Attach, Detach, Bind,
// NoteVersion and reservation reads. The owner never takes those locks.
type Manager[C comparable] struct {
	clock                 func() time.Time
	gatesMu               sync.RWMutex
	gates                 map[string]*gateState
	sessions              map[string]*Session[C]
	disconnectedStableIDs map[string]disconnectedStableID
	gateSweepAt           time.Time
	gateWaitObserver      atomic.Pointer[func(site string, wait time.Duration)]
	capacityCooldownCfg   capacityCooldownConfig
	budgetClampCfg        budgetClampConfig
	capacityRateCfg       capacityRateConfig
	logger                *slog.Logger
}

// Session is one connection's binding. Attach it once; never reuse or copy it
// after attachment. A replacement connection requires a fresh Session.
// Its fields are published through the owner's index before recorders use it.
type Session[C comparable] struct {
	id                   string
	connection           C
	gate                 atomic.Pointer[gateState]
	gateDisconnectedAtNS atomic.Int64
}

func New[C comparable](logger *slog.Logger) Manager[C] { return newManager[C](logger, nil) }

func newManager[C comparable](logger *slog.Logger, clock func() time.Time) Manager[C] {
	return Manager[C]{
		clock:                 clock,
		gates:                 make(map[string]*gateState),
		sessions:              make(map[string]*Session[C]),
		disconnectedStableIDs: make(map[string]disconnectedStableID),
		capacityCooldownCfg:   loadCapacityCooldownConfig(),
		budgetClampCfg:        loadBudgetClampConfig(),
		capacityRateCfg:       loadCapacityRateConfig(),
		logger:                logger,
	}
}

// IdentitySource snapshots the live connection and disconnect identity in one
// index read. The caller derives a live connection's current attested identity
// after this returns, under its own provider lock.
func (r *Manager[C]) IdentitySource(sessionID string) (connection C, identity string, disconnectedAt time.Time, cached bool) {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	if p := r.sessions[sessionID]; p != nil {
		connection = p.connection
	}
	c, cached := r.disconnectedStableIDs[sessionID]
	return connection, c.id, c.at, cached
}

// NoteVersion is called while the live connection's provider lock excludes a
// rebind. Index lookup retains the exact session generation through gate lock.
func (r *Manager[C]) NoteVersion(p *Session[C], version string) {
	r.gatesMu.RLock()
	if r.sessions[p.id] != p {
		r.gatesMu.RUnlock()
		return
	}
	g := p.gate.Load()
	if g == nil || g.key == p.id {
		r.gatesMu.RUnlock()
		return
	}
	g = g.lockResolved()
	r.gatesMu.RUnlock()
	defer g.mu.Unlock()
	now := r.now()
	noteIdentityVersionLocked(g, r, version)
	g.updatedLocked(now)
}
