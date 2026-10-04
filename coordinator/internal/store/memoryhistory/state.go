// Package memoryhistory owns the bounded in-memory history tables.
package memoryhistory

import "github.com/eigeninference/d-inference/coordinator/store"

// State is synchronized by the owning memory store's transaction mutex.
// The tables remain visible to the store for its atomic multi-domain writes.
type State struct {
	Usage                 []store.UsageRecord
	LedgerEntries         []store.LedgerEntry
	DeviceCodesByCode     map[string]*store.DeviceCode // deviceCode → DeviceCode
	DeviceCodesByUserCode map[string]*store.DeviceCode // userCode → DeviceCode
	ProviderEarnings      []store.ProviderEarning
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
		RequestProfiles:       make([]store.RequestProfileRecord, 0),
		RequestProfileKeys:    make(map[string]struct{}),
		FleetSnapshots:        make([]store.FleetSnapshotRow, 0),
		ProviderFloorDraws:    make([]store.ProviderFloorDraw, 0),
	}
}
