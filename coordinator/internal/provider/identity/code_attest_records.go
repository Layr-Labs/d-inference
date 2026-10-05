package identity

import (
	"time"

	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (t *Throttle) RecordAttestedForProcess(
	seKey, version, token, nodeKey, binaryHash string,
) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = proofRecord{
		At: t.Now().Truncate(time.Microsecond), Version: version, Token: token, NodeKey: nodeKey,
		BinaryHash: binaryHash,
	}
	t.mu.Unlock()
}

// invalidateReuse drops any cached reuse record for a device so the NEXT
// code-identity attempt cannot be short-circuited by reuseAttestation and must
// run a real challenge round-trip. Used when a provider's APNs device token
// CHANGES mid-connection (W5 Fix 2): a changed token forces a re-challenge with
// no bypass. This drops only the IN-MEMORY record; the caller also deletes the
// PERSISTED row (Server.invalidatePersistedCodeAttestation) so a coordinator
// restart before the fresh challenge completes cannot reseed and reuse the
// pre-rotation proof (Codex #6).
func (t *Throttle) InvalidateReuse(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	delete(t.attested, seKey)
	t.mu.Unlock()
}

// seed loads persisted attestation records into the in-memory reuse cache at
// startup (W5 Fix 2). It applies the SAME freshness window used on read, so only
// rows that could still be reused are kept (an expired row would be ignored by
// reuseAttestation anyway). It never overwrites a fresher in-memory record (a
// device that reconnected and re-attested before seeding finished). Returns the
// number of rows seeded. SECURITY: seeding only populates the cache;
// reuseAttestation re-validates version, freshness, token, and exact process key
// on every read. A stale, mismatched, or legacy process-key-less row still
// forces a real challenge.
func (t *Throttle) Seed(rows []store.CodeAttestation) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.Now()
	n := 0
	for _, r := range rows {
		if r.SEPubKey == "" {
			continue
		}
		candidate := proofRecord{At: r.AttestedAt, Version: r.Version, Token: r.APNsToken, NodeKey: r.NodePublicKey, BinaryHash: r.BinaryHash, CoveredUntil: trustreuse.CoverageFromStore(r.ContinuousCoverageUntil)}
		if !candidate.Recent(now, t.ReuseWindow) && !candidate.Continuous(now) {
			continue
		}
		if cur, ok := t.attested[r.SEPubKey]; ok && !r.AttestedAt.After(cur.At) {
			continue // keep the fresher in-memory record
		}
		t.attested[r.SEPubKey] = candidate
		n++
	}
	return n
}

// recordChallenge stores the nonce just pushed to a device so the read-loop
// delivery path can match the provider's reply — even one that lands on a
// different (re)connection from the same device (Fix 1). Overwrites any prior
// outstanding challenge for the device (only the latest push is honored).
