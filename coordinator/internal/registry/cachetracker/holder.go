package cachetracker

import (
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// HolderEvidence follows one indexed receipt record into copied routing hints.
// Revocation is read without taking the tracker lock under the provider lock.
type HolderEvidence struct {
	revoked atomic.Bool
}

func (e *HolderEvidence) Current() bool { return e != nil && !e.revoked.Load() }

// Measurement is immutable lookup evidence. A Ready refresh may share it with
// the same holder, but cannot renew its expiry or change its capability binding.
type Measurement struct {
	milliseconds float64
	expiresAt    time.Time
	capability   protocol.PrefixCacheV2Capability
}

func NewMeasurement(milliseconds float64, expiresAt time.Time, capability protocol.PrefixCacheV2Capability) *Measurement {
	return &Measurement{milliseconds: milliseconds, expiresAt: expiresAt, capability: capability}
}
func (m *Measurement) Milliseconds() float64 { return m.milliseconds }
func (m *Measurement) ExpiresAt() time.Time  { return m.expiresAt }
func (m *Measurement) Matches(capability protocol.PrefixCacheV2Capability) bool {
	return m.capability == capability
}

// Holder is a receipt record, not a mutable view into a directory. Provider is
// the captured connection identity and Measurement is a shared immutable sample.
type Holder[P comparable] struct {
	ProviderID              string
	Provider                P
	ModelID                 string
	ModelAggregateHash      string
	PromptContractID        string
	CacheEpoch              string
	BlockHashVersion        string
	ReadyBoundaryMode       string
	Tier                    string
	Anchor                  protocol.PrefixCacheAnchor
	RequiredRecomputeTokens int
	StageMs                 float64
	Measurement             *Measurement
	Evidence                *HolderEvidence
	UpdatedAt               time.Time
	ExpiresAt               time.Time
}

func (h Holder[P]) StageCostAt(now time.Time) float64 {
	if measured := h.Measurement; measured != nil && now.Before(measured.ExpiresAt()) {
		return measured.Milliseconds()
	}
	return h.StageMs
}

func (h Holder[P]) Persistable() bool {
	return h.Tier != "memory" && h.CacheEpoch != "" && h.ModelID != ""
}
