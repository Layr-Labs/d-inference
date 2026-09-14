package codeidentity

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (r proofRecord) recent(now time.Time, window time.Duration) bool {
	age := now.Sub(r.at)
	return age >= -clockSkewTolerance && age < window
}

func (r proofRecord) continuous(now time.Time) bool {
	if r.binaryHash == "" || r.nodeKey == "" || r.token == "" || r.coveredUntil.IsZero() || r.coveredUntil.Before(r.at) {
		return false
	}
	gap := now.Sub(r.coveredUntil)
	return gap >= 0 && gap <= codeAttestContinuityGap
}

func (r proofRecord) persisted(seKey string) store.CodeAttestation {
	out := store.CodeAttestation{SEPubKey: seKey, Version: r.version, AttestedAt: r.at,
		APNsToken: r.token, NodePublicKey: r.nodeKey, BinaryHash: r.binaryHash}
	if !r.coveredUntil.IsZero() {
		until := r.coveredUntil
		out.ContinuousCoverageUntil = &until
	}
	return out
}

// reuseAttestation reports whether the device attested recently with the same
// binary version, exact current non-empty APNs token, and exact registration-
// bound process node key that decrypted E_K(nonce). Legacy token-less or
// process-key-less rows are never reusable authorization inputs; they must
// bootstrap a real push. Old proofs additionally require recorded same-process
// verified continuity within codeAttestContinuityGap.
func (t *deviceState) reuseAttestation(seKey, version, token, nodeKey string) bool {
	return t.reuseAttestationBasis(seKey, version, token, nodeKey) != ""
}

func (t *deviceState) reuseAttestationBasis(seKey, version, token, nodeKey string) string {
	if seKey == "" || version == "" || token == "" || nodeKey == "" {
		return ""
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok || r.version != version || r.token != token || r.nodeKey != nodeKey {
		return ""
	}
	now := t.now()
	if r.recent(now, t.reuseWindow) {
		return "recent_apns"
	}
	if r.continuous(now) {
		return "process_continuity"
	}
	return ""
}

// reuseAttestationForTransition supplies the genuine Apple/APNs half of an
// approved release transition, returning the SE-attested binary identity the
// cached proof was earned under. Version may differ, and — unlike same-version
// reuseAttestation — the cached proof's process key may differ from the current
// one: the provider generates a fresh ephemeral NodeKeyPair on every process
// start, so requiring key equality here would push the whole fleet on every
// routine upgrade/restart and strand providers behind the durable APNs floor
// while queued requests expire. The proof must still be fresh, bound to the
// same SE identity and exact current non-empty token, must itself carry a
// process-key binding, and must record WHICH binary earned it (a legacy
// unbound or identity-less row never authorizes a transition). The CALLER
// (TryResumeApproved) then decides whether that recorded identity — same
// binary, or an APPROVED active predecessor of the current release — may
// transition; a proof earned by a deactivated/unknown release falls through to
// a real APNs challenge.
// SECURITY: this only authorizes SENDING a live encrypted resume challenge to
// the CURRENT registration process key; possession of that new key is proven
// solely by decrypting E_K(nonce), and the SE signature over the recovered
// nonce is still verified — the cached record never grants trust by itself.
func (t *deviceState) reuseAttestationForTransition(
	seKey, token string,
) (string, bool) {
	if seKey == "" || token == "" {
		return "", false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok ||
		r.token != token ||
		r.nodeKey == "" ||
		r.binaryHash == "" ||
		!r.recent(t.now(), t.reuseWindow) {
		return "", false
	}
	return r.binaryHash, true
}

func (t *deviceState) recordAttested(seKey, version, token string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = proofRecord{at: t.now(), version: version, token: token}
	t.mu.Unlock()
}

func (t *deviceState) recordAttestedForProcess(
	seKey, version, token, nodeKey, binaryHash string,
) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	t.attested[seKey] = proofRecord{
		at: t.now().Truncate(time.Microsecond), version: version, token: token, nodeKey: nodeKey,
		binaryHash: binaryHash,
	}
	t.mu.Unlock()
}

// invalidateReuse drops any cached reuse record for a device so the NEXT
// code-identity attempt cannot be short-circuited by reuseAttestation and must
// run a real challenge round-trip. Used when a provider's APNs device token
// CHANGES mid-connection: a changed token forces a re-challenge with
// no bypass. This drops only the IN-MEMORY record; the caller also deletes the
// PERSISTED row (Server.invalidatePersistedCodeAttestation) so a coordinator
// restart before the fresh challenge completes cannot reseed and reuse the
// pre-rotation proof.
func (t *deviceState) invalidateReuse(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	delete(t.attested, seKey)
	t.mu.Unlock()
}

// seed loads persisted attestation records into the in-memory reuse cache at
// startup. It applies the SAME freshness window used on read, so only
// rows that could still be reused are kept (an expired row would be ignored by
// reuseAttestation anyway). It never overwrites a fresher in-memory record (a
// device that reconnected and re-attested before seeding finished). Returns the
// number of rows seeded. SECURITY: seeding only populates the cache;
// reuseAttestation re-validates version, freshness, token, and exact process key
// on every read. A stale, mismatched, or legacy process-key-less row still
// forces a real challenge.
func (t *deviceState) seed(rows []store.CodeAttestation) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	n := 0
	for _, r := range rows {
		if r.SEPubKey == "" {
			continue
		}
		candidate := proofRecord{at: r.AttestedAt, version: r.Version, token: r.APNsToken, nodeKey: r.NodePublicKey, binaryHash: r.BinaryHash, coveredUntil: trustreuse.CoverageFromStore(r.ContinuousCoverageUntil)}
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
