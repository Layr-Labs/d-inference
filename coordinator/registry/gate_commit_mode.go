package registry

import (
	"log/slog"
	"os"
	"strings"
)

// gate_commit_mode.go — the EIGENINFERENCE_RESERVE_COMMIT_MODE kill switch:
// how the reservation commit holds the registry lock (shared RLock, or the
// fleet-wide write lock it replaced). Design and file map: gate_state.go.

// --- reservation commit lock mode ---

// reserveCommitMode selects how commitProviderReservation and
// ReserveNextFromPlan hold the registry lock while they debit a provider.
type reserveCommitMode uint8

const (
	// reserveCommitShared (default) commits under r.mu.RLock + p.mu: the
	// double-booking guard is the admit re-check under p.mu, the herd guard
	// is the "winner unchanged since scan" compare under the same p.mu, and
	// the probe claim is atomic under gate.mu. Commits no longer drain the
	// fleet-scan reader batch.
	reserveCommitShared reserveCommitMode = iota
	// reserveCommitGlobal is the kill switch: commits take r.mu.Lock() and
	// serialize fleet-wide exactly as before. The recorders stay on their
	// per-identity gates in both modes — that half is safe on its own.
	reserveCommitGlobal
)

// envReserveCommitMode selects the mode: "global" restores the fleet-wide
// commit serialization; anything else (including unset) is "shared". Read
// once at Registry construction.
const envReserveCommitMode = "EIGENINFERENCE_RESERVE_COMMIT_MODE"

func loadReserveCommitMode(logger *slog.Logger) reserveCommitMode {
	raw := os.Getenv(envReserveCommitMode)
	mode, known := parseReserveCommitMode(raw)
	if !known && logger != nil {
		// A kill switch that silently ignores a typo is not a kill switch.
		logger.Warn("unknown reserve commit mode; using shared",
			"env", envReserveCommitMode, "value", raw)
	}
	return mode
}

// parseReserveCommitMode maps the raw value to a mode; known reports whether
// the value named one ("" and "shared" are shared, "global" is global).
func parseReserveCommitMode(raw string) (mode reserveCommitMode, known bool) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "shared":
		return reserveCommitShared, true
	case "global":
		return reserveCommitGlobal, true
	default:
		return reserveCommitShared, false
	}
}

func (m reserveCommitMode) String() string {
	if m == reserveCommitGlobal {
		return "global"
	}
	return "shared"
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
