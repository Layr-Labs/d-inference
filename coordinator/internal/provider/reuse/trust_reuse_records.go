package reuse

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func trustReuseRecordFromStore(rec store.ProviderTrustReuse) Record {
	return Record{
		Serial:                     rec.Serial,
		TrustLevel:                 rec.TrustLevel,
		LastVerifiedBinaryHash:     rec.LastVerifiedBinaryHash,
		SipEnabled:                 rec.SIPEnabled,
		SecureBootFull:             rec.SecureBootFull,
		MdaUDID:                    rec.MDAUDID,
		HardwareProofVerifiedAt:    rec.HardwareProofVerifiedAt,
		ApplicationProofVerifiedAt: rec.ApplicationProofVerifiedAt,
		ContinuousCoverageUntil:    CoverageFromStore(rec.ContinuousCoverageUntil),
		EvidenceGeneration:         rec.EvidenceGeneration,
		RevocationGeneration:       rec.RevocationGeneration,
		RevocationEventID:          rec.RevocationEventID,
		revokedAt:                  rec.RevokedAt,
	}
}

func CoverageFromStore(until *time.Time) time.Time {
	if until == nil {
		return time.Time{}
	}
	return *until
}

func CoverageToStore(until time.Time) *time.Time {
	if until.IsZero() {
		return nil
	}
	return &until
}

// advanceCoverage moves the in-memory continuity watermark forward for the
// given identities. Mirrors the store's monotonic guard: never backward, never
// on a tombstoned or non-hardware record.
func (c *Cache) AdvanceCoverage(seKeys []string, until time.Time) {
	if until.IsZero() {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, seKey := range seKeys {
		r, ok := c.records[seKey]
		if !ok || r.revokedAt != nil ||
			r.TrustLevel != string(registry.TrustHardware) ||
			!until.After(r.ContinuousCoverageUntil) {
			continue
		}
		r.ContinuousCoverageUntil = until
		c.records[seKey] = r
	}
}

func (c *Cache) RecordTrust(rec store.ProviderTrustReuse) {
	if rec.SEPubKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if current, ok := c.records[rec.SEPubKey]; ok {
		if current.revokedAt != nil ||
			current.RevocationGeneration != rec.RevocationGeneration {
			return
		}
	}
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
}

func (c *Cache) RecoverTrust(rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) bool {
	if rec.SEPubKey == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if current, ok := c.records[rec.SEPubKey]; ok &&
		current.RevocationGeneration != expectedRevocationGeneration {
		return false
	}
	rec.RevocationGeneration = expectedRevocationGeneration
	rec.RevokedAt = nil
	c.records[rec.SEPubKey] = trustReuseRecordFromStore(rec)
	return true
}

func (c *Cache) RevocationState(seKey string) (uint64, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	return rec.RevocationGeneration, rec.RevocationEventID
}

func (c *Cache) IsRevoked(seKey string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	rec, ok := c.records[seKey]
	return ok && rec.revokedAt != nil
}

func (c *Cache) InvalidateReuse(seKey, RevocationEventID string) uint64 {
	if seKey == "" || RevocationEventID == "" {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	if rec.RevocationEventID == RevocationEventID {
		return rec.RevocationGeneration
	}
	rec.TrustLevel = ""
	rec.RevocationGeneration++
	rec.RevocationEventID = RevocationEventID
	Now := c.Now().UTC()
	rec.revokedAt = &Now
	c.records[seKey] = rec
	return rec.RevocationGeneration
}

func (c *Cache) InstallRevocationGeneration(seKey string, generation uint64) {
	if seKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rec := c.records[seKey]
	if rec.RevocationGeneration > generation {
		return
	}
	rec.TrustLevel = ""
	rec.RevocationGeneration = generation
	Now := c.Now().UTC()
	rec.revokedAt = &Now
	c.records[seKey] = rec
}

func (c *Cache) InstallAuthoritativeTrustReuse(rec store.ProviderTrustReuse) {
	if rec.SEPubKey == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	current := c.records[rec.SEPubKey]
	if current.RevocationGeneration > rec.RevocationGeneration {
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
// (Codex P1). Staleness never grants anything: decideTrustReuse and
// hasFreshRecord re-run the freshness/continuity gates on every read, so a
// retained expired/future-dated row is pure generation state. The return value
// counts only rows currently admissible for reuse (logging).
func (c *Cache) Seed(rows []store.ProviderTrustReuse) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, row := range rows {
		if row.SEPubKey == "" {
			continue
		}
		incoming := trustReuseRecordFromStore(row)
		current, ok := c.records[row.SEPubKey]
		if ok && current.RevocationGeneration > incoming.RevocationGeneration {
			continue
		}
		if ok && current.RevocationGeneration == incoming.RevocationGeneration {
			if current.revokedAt != nil {
				continue
			}
			if !incoming.HardwareProofVerifiedAt.After(current.HardwareProofVerifiedAt) {
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
