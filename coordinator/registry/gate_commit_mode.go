package registry

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/reservation"
)

// gate_commit_mode.go — the EIGENINFERENCE_RESERVE_COMMIT_MODE kill switch:
// how the reservation commit holds the registry lock (shared RLock, or the
// fleet-wide write lock it replaced). Design and file map: gate_state.go.

// --- reservation commit lock mode ---

// reserveCommitMode selects how commitProviderReservation and
// ReserveNextFromPlan hold the registry lock while they debit a provider.
type reserveCommitMode = reservation.CommitMode

const (
	// reserveCommitGlobal is the kill switch: commits take r.mu.Lock() and
	// serialize fleet-wide exactly as before. The recorders stay on their
	// per-identity gates in both modes — that half is safe on its own.
	reserveCommitGlobal = reservation.Global
)

func loadReserveCommitMode(logger *slog.Logger) reserveCommitMode {
	return reservation.LoadCommitMode(logger)
}

// commitLock is the registry lock held across a reservation commit in the
// configured mode. A value type so the commit path allocates nothing.
type commitLock struct {
	r      *Registry
	global bool
	site   string
	write  writeHold
}

func (r *Registry) commitLock(site string) commitLock {
	return commitLock{r: r, global: r.reserveCommitMode == reserveCommitGlobal, site: site}
}

func (l *commitLock) lock() {
	if l.global {
		l.write = l.r.lockWrite(l.site)
	} else {
		l.r.mu.RLock()
	}
}

func (l *commitLock) unlock() {
	if l.global {
		l.write.unlock()
	} else {
		l.r.mu.RUnlock()
	}
}
