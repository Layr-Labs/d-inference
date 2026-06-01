package api

import (
	"context"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// mergeFleet builds a deduplicated list of myProvider structs for an account
// by combining persisted ProviderRecords (covers offline machines) with the
// live registry snapshot (status, heartbeat metrics, backend capacity).
func (s *Server) mergeFleet(ctx context.Context, accountID string) ([]myProvider, error) {
	records, err := s.store.ListProvidersByAccount(ctx, accountID)
	if err != nil {
		return nil, fmt.Errorf("list providers by account: %w", err)
	}

	// Index live providers by both session ID and stable identity (serial /
	// SE key) so reconnected machines — whose session ID differs from the
	// stored record's ID — still match their persisted state.
	liveByID := make(map[string]*registry.Provider)
	liveByIdentity := make(map[string]*registry.Provider)
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		if p.AccountID == accountID {
			liveByID[p.ID] = p
			if p.AttestationResult != nil {
				if p.AttestationResult.SerialNumber != "" {
					liveByIdentity["serial:"+p.AttestationResult.SerialNumber] = p
				}
				if p.AttestationResult.PublicKey != "" {
					liveByIdentity["sekey:"+p.AttestationResult.PublicKey] = p
				}
			}
		}
		p.Mu().Unlock()
	})

	deduped := dedupeRecordsByIdentity(records)
	seenIDs := make(map[string]bool, len(deduped))
	seenLive := make(map[string]bool)
	out := make([]myProvider, 0, len(deduped))
	for i := range deduped {
		// Prefer session-ID match; fall back to identity (serial/SE key)
		// so reconnected machines correctly show as online.
		live := liveByID[deduped[i].ID]
		if live == nil {
			live = liveByIdentity[recordIdentity(&deduped[i])]
		}
		mp := buildMyProvider(&deduped[i], live)
		out = append(out, mp)
		seenIDs[deduped[i].ID] = true
		if live != nil {
			seenLive[live.ID] = true
		}
	}
	for id, p := range liveByID {
		if seenIDs[id] || seenLive[id] {
			continue
		}
		if liveMatchesEmittedIdentity(p, out) {
			continue
		}
		out = append(out, buildMyProvider(nil, p))
	}
	return out, nil
}
