package verification

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// StageMDA recovers a previously-earned Apple MDA cert chain from the
// store (by serial) and stages it on the provider as a reuse candidate for this
// reconnect. A missing record / chain or a read error stages nothing, and a
// fresh attestation is requested. This read is independent of counter recovery.
func (s *Verifier) StageMDA(provider *registry.Provider, serial string) {
	if s.deps.Store() == nil || serial == "" {
		return
	}
	// Bound the store read: this runs on the attestation path, so a slow or
	// unavailable Postgres must not stall it — on timeout we skip staging and fall
	// back to a fresh attestation.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	// Newest NON-EMPTY chain for this serial: a reconnect persists a new row that
	// may briefly carry an empty chain (async persists race the reattach), which
	// would shadow a still-valid chain via a plain by-serial lookup. This looks
	// past those empty rows.
	chain, err := s.deps.Store().GetMDAChainBySerial(ctx, serial)
	if err != nil || len(chain) == 0 {
		return
	}
	provider.StageMDAChainFromJSON(chain)
}
