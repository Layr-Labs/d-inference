package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// recordIdentity returns the stable identity for a provider record, preferring
// SerialNumber, then SEPublicKey, then the per-session ID as a last resort.
// Two records with the same identity refer to the same physical machine.
func recordIdentity(rec *store.ProviderRecord) string {
	if rec.SerialNumber != "" {
		return "serial:" + rec.SerialNumber
	}
	if rec.SEPublicKey != "" {
		return "sekey:" + rec.SEPublicKey
	}
	return "id:" + rec.ID
}

// liveIdentity computes the same stable identity for a live registry provider
// using the same serial/SE-key precedence so dedup keys are comparable.
func liveIdentity(p *registry.Provider) string {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.AttestationResult != nil {
		if p.AttestationResult.SerialNumber != "" {
			return "serial:" + p.AttestationResult.SerialNumber
		}
		if p.AttestationResult.PublicKey != "" {
			return "sekey:" + p.AttestationResult.PublicKey
		}
	}
	return "id:" + p.ID
}

// dedupeRecordsByIdentity collapses ProviderRecord rows that refer to the
// same physical machine, keeping the most recently seen one. The input order
// is the store's LastSeen-DESC order; we honour it for ties.
func dedupeRecordsByIdentity(records []store.ProviderRecord) []store.ProviderRecord {
	if len(records) <= 1 {
		return records
	}
	picked := make(map[string]int, len(records))
	for i := range records {
		key := recordIdentity(&records[i])
		if existing, ok := picked[key]; !ok || records[i].LastSeen.After(records[existing].LastSeen) {
			picked[key] = i
		}
	}
	out := make([]store.ProviderRecord, 0, len(picked))
	for i := range records {
		if picked[recordIdentity(&records[i])] == i {
			out = append(out, records[i])
		}
	}
	return out
}

// liveMatchesEmittedIdentity reports whether the live provider corresponds to
// a machine we already emitted from the persisted-records pass. This avoids
// duplicating a card when a stored record's session ID drifted from the live
// session ID (post-reconnect) but they share a serial/SE key.
func liveMatchesEmittedIdentity(p *registry.Provider, emitted []myProvider) bool {
	id := liveIdentity(p)
	for i := range emitted {
		if emittedIdentity(&emitted[i]) == id {
			return true
		}
	}
	return false
}

func emittedIdentity(mp *myProvider) string {
	if mp.SerialNumber != "" {
		return "serial:" + mp.SerialNumber
	}
	if mp.SEPublicKey != "" {
		return "sekey:" + mp.SEPublicKey
	}
	return "id:" + mp.ID
}
