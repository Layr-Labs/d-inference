package identitygate

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// Options binds policy and the mutation clock before a directory is published.
// A nil Options selects the environment-backed production policy defaults.
type Options struct {
	CapacityCooldown      CapacityCooldownConfig
	CapacityRate          CapacityRateConfig
	BudgetClamp           BudgetClampConfig
	Now                   func() time.Time
	HealthEjectionEnabled func() bool
}

// DefaultOptions reads the same restart-scoped policies as the registry.
func DefaultOptions() Options {
	return Options{
		CapacityCooldown: LoadCapacityCooldownConfig(),
		CapacityRate:     LoadCapacityRateConfig(),
		BudgetClamp:      LoadBudgetClampConfig(),
	}
}

// Directory owns identity bindings and fault state independently of providers.
// External Registry and Provider critical sections precede its index and state
// locks. No operation acquires a caller's lock while holding either owned lock.
type Directory struct {
	gatesMu               sync.RWMutex
	gates                 map[string]*State
	sessions              map[string]*Session
	disconnectedStableIDs map[string]disconnectedStableID
	gateSweepAt           time.Time
	gateWaitObserver      atomic.Pointer[func(string, time.Duration)]
	capacityCooldownCfg   CapacityCooldownConfig
	capacityRateCfg       CapacityRateConfig
	budgetClampCfg        BudgetClampConfig
	logger                *slog.Logger
	now                   func() time.Time
	healthEjectionEnabled func() bool
}

// Session is a directory-owned binding, not a provider or a transport handle.
type Session struct {
	id                   string
	gate                 atomic.Pointer[State]
	gateDisconnectedAtNS atomic.Int64
}

func New(logger *slog.Logger, options *Options) *Directory {
	config := DefaultOptions()
	if options != nil {
		config = *options
	}
	if logger == nil {
		logger = slog.Default()
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.HealthEjectionEnabled == nil {
		config.HealthEjectionEnabled = func() bool { return true }
	}
	return &Directory{
		gates:                 make(map[string]*State),
		sessions:              make(map[string]*Session),
		disconnectedStableIDs: make(map[string]disconnectedStableID),
		capacityCooldownCfg:   config.CapacityCooldown,
		capacityRateCfg:       config.CapacityRate,
		budgetClampCfg:        config.BudgetClamp,
		logger:                logger,
		now:                   config.Now,
		healthEjectionEnabled: config.HealthEjectionEnabled,
	}
}

// Attach creates the binding before its caller publishes a connected provider.
func (r *Directory) Attach(id string) *Session {
	session := &Session{id: id}
	r.attachSessionGate(session)
	return session
}

func (r *Directory) Detach(session *Session, stableID string) {
	r.detachSessionGate(session, stableID)
}

func (r *Directory) Bind(session *Session, stableID, version string) {
	r.bindSessionFaultKey(session, stableID, version)
}

// ResolveSession captures an outcome's binding for later validated recording.
func (r *Directory) ResolveSession(id string, insert bool) Reference {
	return r.sessionGateRef(id, insert)
}

func (r *Directory) ResolveIdentity(key string) Reference {
	return r.gateForKey(key)
}

// ReferenceForSession is the reservation path's allocation-free resolution.
func (r *Directory) ReferenceForSession(session *Session, id string) Reference {
	if session != nil {
		if state := session.gate.Load(); state != nil {
			return Reference{g: state.resolve(), p: session, session: id}
		}
	}
	return r.lookupSessionGateRef(id)
}

func (r *Directory) FaultKeyForSession(id string) string {
	return r.faultKeyForSession(id)
}

// DisconnectedIdentity resolves only the still-live trailing-outcome cache.
func (r *Directory) DisconnectedIdentity(id string) string {
	r.gatesMu.RLock()
	cached, ok := r.disconnectedStableIDs[id]
	r.gatesMu.RUnlock()
	if ok && r.now().Sub(cached.at) < disconnectedStableIDTTL {
		return cached.id
	}
	return ""
}

// Sweep retires only unreferenced idle identities and reports retained entries.
func (r *Directory) Sweep(now time.Time) int {
	return r.Maintain(now).Retained
}

// MaintenanceReport describes the retained evidence after pruning and retirement.
// RetiredIndexed is an invariant violation: a retired state remained published.
type MaintenanceReport struct {
	Retained         int
	Retired          int
	RetiredIndexed   int
	AttachedSessions int
	Inference        InferenceRetention
}

// Maintain performs the same bounded lifecycle maintenance used by the inline
// high-water sweep and reports its resulting retained evidence, not mutable state.
func (r *Directory) Maintain(now time.Time) MaintenanceReport {
	return r.MaintainWithRetention(DefaultRetention(now))
}

// RetentionCutoffs separates evidence freshness from disconnected-session and
// idle-identity retention. All three cutoffs are captured before maintenance.
type RetentionCutoffs struct {
	HistoryNow         time.Time
	DisconnectedBefore time.Time
	IdleBefore         time.Time
}

func DefaultRetention(now time.Time) RetentionCutoffs {
	return RetentionCutoffs{
		HistoryNow:         now,
		DisconnectedBefore: now.Add(-disconnectedStableIDTTL),
		IdleBefore:         now.Add(-gateIdleGrace),
	}
}

func (r *Directory) MaintainWithRetention(retention RetentionCutoffs) MaintenanceReport {
	r.gatesMu.Lock()
	defer r.gatesMu.Unlock()
	r.gatesInitLocked()
	return r.sweepGatesWithRetentionLocked(retention)
}
