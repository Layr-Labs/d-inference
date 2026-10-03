package trust

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (t *codeAttestThrottle) recordAttested(seKey, version, token string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = codeAttestRecord{at: t.now(), version: version, token: token}
	t.mu.Unlock()
}

func (t *codeAttestThrottle) recordAttestedForProcess(
	seKey, version, token, nodeKey, binaryHash string,
) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = codeAttestRecord{
		at: t.now().Truncate(time.Microsecond), version: version, token: token, nodeKey: nodeKey,
		binaryHash: binaryHash,
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
func (t *codeAttestThrottle) invalidateReuse(seKey string) {
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
func (t *codeAttestThrottle) seed(rows []store.CodeAttestation) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	n := 0
	for _, r := range rows {
		if r.SEPubKey == "" {
			continue
		}
		candidate := codeAttestRecord{at: r.AttestedAt, version: r.Version, token: r.APNsToken, nodeKey: r.NodePublicKey, binaryHash: r.BinaryHash, coveredUntil: coverageFromStore(r.ContinuousCoverageUntil)}
		if !candidate.recent(now, t.reuseWindow) && !candidate.continuous(now) {
			continue
		}
		if cur, ok := t.attested[r.SEPubKey]; ok && !r.AttestedAt.After(cur.at) {
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
