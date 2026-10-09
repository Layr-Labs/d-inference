// Package memoryhistory owns the bounded in-memory history tables.
package memoryhistory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// EarningSource retains attribution, not money, after bounded history is pruned.
type EarningSource struct {
	AccountID   string
	ProviderID  string
	ProviderKey string
}

// SessionUptimeWindow identifies possible coverage lost when a session row is
// pruned. A zero End is unbounded: an open session may continue receiving
// heartbeats after its raw history row is removed.
type SessionUptimeWindow struct {
	AccountID string
	Start     time.Time
	End       time.Time
}

// State is synchronized by the owning memory store's transaction mutex.
// The tables remain visible to the store for its atomic multi-domain writes.
type State struct {
	Usage                 []store.UsageRecord
	LedgerEntries         []store.LedgerEntry
	DeviceCodesByCode     map[string]*store.DeviceCode // deviceCode → DeviceCode
	DeviceCodesByUserCode map[string]*store.DeviceCode // userCode → DeviceCode
	ProviderEarnings      []store.ProviderEarning
	// Windows starting at or before a source's watermark may be incomplete.
	EarningsPrunedThrough map[EarningSource]time.Time
	ProviderKeysPruned    map[string]bool                // account -> incomplete fallback-key associations
	ProviderUptimePruned  map[string]SessionUptimeWindow // session -> missing uptime evidence
	LogReports            []store.LogReport
	ProviderSessions      []store.ProviderSession
	ProviderSessionSeq    int64
	RequestOutcomes       map[string]store.RequestOutcomeRecord
	RequestProfiles       []store.RequestProfileRecord
	RequestProfileKeys    map[string]struct{} // request_id/attempt -> present
	FleetSnapshots        []store.FleetSnapshotRow
	ProviderFloorDraws    []store.ProviderFloorDraw
}

func New() *State {
	return &State{
		Usage:                 make([]store.UsageRecord, 0),
		LedgerEntries:         make([]store.LedgerEntry, 0),
		DeviceCodesByCode:     make(map[string]*store.DeviceCode),
		DeviceCodesByUserCode: make(map[string]*store.DeviceCode),
		ProviderEarnings:      make([]store.ProviderEarning, 0),
		EarningsPrunedThrough: make(map[EarningSource]time.Time),
		ProviderKeysPruned:    make(map[string]bool),
		ProviderUptimePruned:  make(map[string]SessionUptimeWindow),
		RequestProfiles:       make([]store.RequestProfileRecord, 0),
		RequestProfileKeys:    make(map[string]struct{}),
		FleetSnapshots:        make([]store.FleetSnapshotRow, 0),
		ProviderFloorDraws:    make([]store.ProviderFloorDraw, 0),
	}
}
