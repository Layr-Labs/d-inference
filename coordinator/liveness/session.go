package liveness

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// SessionTracker maps live providerID → open session row id so the
// coordinator's existing Register / Disconnect / evictStale call sites can
// reference sessions without threading the int64 id through three layers.
//
// All store calls are synchronous and short — session open/close are
// per-connection events, not hot-path. We do NOT batch them.
type SessionTracker struct {
	store         store.Store
	logger        *slog.Logger
	count         CounterFn
	coordinatorID string
	timeout       time.Duration

	mu   sync.Mutex
	open map[string]int64 // providerID → sessionID
}

// NewSessionTracker constructs a tracker. coordinatorID is stamped into each
// row so future debugging can distinguish which coordinator instance owned a
// session (matters during blue/green deploys). count may be nil.
func NewSessionTracker(s store.Store, logger *slog.Logger, count CounterFn, coordinatorID string) *SessionTracker {
	if logger == nil {
		logger = slog.Default()
	}
	return &SessionTracker{
		store:         s,
		logger:        logger.With("component", "liveness.sessions"),
		count:         count,
		coordinatorID: coordinatorID,
		timeout:       5 * time.Second,
		open:          make(map[string]int64),
	}
}

// Open records a new session for the given provider. If the provider already
// has an open session (e.g. a reconnect we never saw closed), the old session
// is left alone — orphan-close on next coordinator boot will sweep it. We
// always create a fresh row so the new session has a clean ID.
func (t *SessionTracker) Open(providerID string) {
	ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
	defer cancel()

	id, err := t.store.OpenSession(ctx, store.SessionStart{
		ProviderID:    providerID,
		ConnectedAt:   time.Now(),
		CoordinatorID: t.coordinatorID,
	})
	if err != nil {
		t.logger.Warn("open session failed",
			"provider_id", providerID,
			"error", err)
		return
	}
	t.mu.Lock()
	t.open[providerID] = id
	t.mu.Unlock()
}

// Close marks the provider's currently-open session as disconnected.
// reason should be one of the store.DisconnectReason* constants.
// lastHeartbeat / requestsServed / tokensGenerated are optional context for
// post-hoc analysis; pass zero values if not tracked.
//
// Idempotent: a second call for the same provider is a no-op.
func (t *SessionTracker) Close(providerID, reason string, lastHeartbeat time.Time, requestsServed, tokensGenerated int64) {
	t.mu.Lock()
	id, ok := t.open[providerID]
	if ok {
		delete(t.open, providerID)
	}
	t.mu.Unlock()
	if !ok {
		// No tracked session — either we missed the Open (eg. coordinator
		// restart) or this is a duplicate Close. Either way, nothing to
		// update. CloseOrphanSessions on the next boot will catch the gap.
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
	defer cancel()
	if err := t.store.CloseSession(ctx, id, reason, time.Now(), lastHeartbeat, requestsServed, tokensGenerated); err != nil {
		// Tracker has already forgotten the session (delete above). The
		// row stays OPEN in Postgres; orphan-sweep on next coordinator
		// boot will reconcile. Surface the gap so operators can alarm
		// before the next reboot.
		if t.count != nil {
			t.count("liveness_session_close_failed_total", 1)
		}
		t.logger.Warn("close session failed",
			"provider_id", providerID,
			"session_id", id,
			"reason", reason,
			"error", err)
	}
}

// CloseOrphans is called once on coordinator boot to close any sessions left
// open by a previous coordinator process (crash or unclean shutdown). All
// matching rows owned by THIS coordinatorID are stamped with
// reason=coordinator_restart. Sessions owned by a sibling coordinator (e.g.
// during a blue-green deploy) are left alone — they're still live there.
func (t *SessionTracker) CloseOrphans(ctx context.Context) (int64, error) {
	return t.store.CloseOrphanSessions(ctx, store.DisconnectReasonCoordinatorRestart, time.Now(), t.coordinatorID)
}
