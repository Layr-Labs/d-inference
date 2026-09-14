package trustreuse

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

// advanceCoverage moves the in-memory continuity watermark forward for the
// given identities. Mirrors the store's monotonic guard: never backward, never
// on a tombstoned or non-hardware record.
func (c *cache) advanceCoverage(seKeys []string, until time.Time) {
	if until.IsZero() {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, seKey := range seKeys {
		r, ok := c.records[seKey]
		if !ok || r.revokedAt != nil ||
			r.trustLevel != string(registry.TrustHardware) ||
			!until.After(r.continuousCoverageUntil) {
			continue
		}
		r.continuousCoverageUntil = until
		c.records[seKey] = r
	}
}

func (c *cache) recordTrust(rec store.ProviderTrustReuse) {
	if rec.SEPubKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if current, ok := c.records[rec.SEPubKey]; ok {
		if current.revokedAt != nil ||
			current.revocationGeneration != rec.RevocationGeneration {
			return
		}
	}
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
}

func (c *cache) recoverTrust(rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) bool {
	if rec.SEPubKey == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if current, ok := c.records[rec.SEPubKey]; ok &&
		current.revocationGeneration != expectedRevocationGeneration {
		return false
	}
	rec.RevocationGeneration = expectedRevocationGeneration
	rec.RevokedAt = nil
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
	return true
}

func (c *cache) revocationState(seKey string) (uint64, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	return rec.revocationGeneration, rec.revocationEventID
}

func (c *cache) isRevoked(seKey string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	rec, ok := c.records[seKey]
	return ok && rec.revokedAt != nil
}

func (c *cache) invalidateReuse(seKey, revocationEventID string) uint64 {
	if seKey == "" || revocationEventID == "" {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	if rec.revocationEventID == revocationEventID {
		return rec.revocationGeneration
	}
	rec.trustLevel = ""
	rec.revocationGeneration++
	rec.revocationEventID = revocationEventID
	now := c.now().UTC()
	rec.revokedAt = &now
	c.records[seKey] = rec
	return rec.revocationGeneration
}

func (c *cache) installRevocationGeneration(seKey string, generation uint64) {
	if seKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	if rec.revocationGeneration > generation {
		return
	}
	rec.trustLevel = ""
	rec.revocationGeneration = generation
	now := c.now().UTC()
	rec.revokedAt = &now
	c.records[seKey] = rec
}

func (c *cache) installAuthoritativeTrustReuse(rec store.ProviderTrustReuse) {
	if rec.SEPubKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	current := c.records[rec.SEPubKey]
	if current.revocationGeneration > rec.RevocationGeneration {
		return
	}
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
}

// seed installs persisted rows into the cache at startup. Every keyed row is
// RETAINED — including rows whose freshness has lapsed — because a row's
// RevocationGeneration is durable CAS state, not just reuse evidence: dropping
// an expired row for a previously-revoked-then-recovered device would make the
// next full live MDM grant submit expected generation zero, lose the recovery
// CAS against the durable row, and be misclassified as a transient failure
// (Codex P1). Staleness never grants anything: decide and
// hasFreshRecord re-run the freshness/continuity gates on every read, so a
// retained expired/future-dated row is pure generation state. The return value
// counts only rows currently admissible for reuse (logging).
func (c *cache) seed(rows []store.ProviderTrustReuse) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, row := range rows {
		if row.SEPubKey == "" {
			continue
		}
		incoming := trustReuseRecordFromStore(row)
		current, ok := c.records[row.SEPubKey]
		if ok && current.revocationGeneration > incoming.revocationGeneration {
			continue
		}
		if ok && current.revocationGeneration == incoming.revocationGeneration {
			if current.revokedAt != nil {
				continue
			}
			if !incoming.hardwareProofVerifiedAt.After(current.hardwareProofVerifiedAt) {
				continue
			}
		}
		c.records[row.SEPubKey] = incoming
		if incoming.revokedAt == nil {
			if _, admissible := c.freshnessLocked(incoming); admissible {
				n++
			}
		}
	}
	return n
}
