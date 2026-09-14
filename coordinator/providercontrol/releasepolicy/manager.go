// Package releasepolicy owns approved provider release and runtime policy.
// It synchronizes inventory, carries valid evidence between generations, and
// revalidates the connected fleet without changing its process identity.
package releasepolicy

import (
	"sync"
	"sync/atomic"
)

// Manager owns one policy state per coordinator. Dependencies are resolved at
// their original read boundaries; no worker or additional resync is started.
type Manager struct {
	deps                              Dependencies
	releasePolicySyncMu               sync.Mutex
	binaryHashPolicyMu                sync.RWMutex
	knownBinaryHashes                 map[string]bool
	manualKnownBinaryHashes           map[string]bool
	releaseKnownBinaryHashes          map[string]bool
	manualBinaryHashPolicyConfigured  bool
	releaseBinaryHashPolicyConfigured bool
	binaryHashPolicyConfigured        bool
	releaseTrustPolicy                atomic.Pointer[Snapshot]
	releaseTrustPolicyGeneration      atomic.Uint64
	releaseInventoryEverConfigured    atomic.Bool

	knownRuntimeManifest *RuntimeManifest
}

func New(deps Dependencies) *Manager { return &Manager{deps: deps} }

// Snapshot returns the currently published immutable policy, or nil before sync.
func (s *Manager) Snapshot() *Snapshot { return s.releaseTrustPolicy.Load() }

// RuntimeManifest returns the current configuration. Treat published maps as
// read-only; SetRuntimeManifest preserves the existing caller-owned setup API.
func (s *Manager) RuntimeManifest() *RuntimeManifest { return s.knownRuntimeManifest }
