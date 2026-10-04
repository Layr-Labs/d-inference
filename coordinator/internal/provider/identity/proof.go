package identity

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// ProofForIdentity captures a proof only for the exact process that earned it.
func (t *Throttle) ProofForIdentity(seKey, version, token, nodeKey, binaryHash string) (store.CodeAttestation, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok || r.Version != version || r.Token != token || r.NodeKey != nodeKey || r.BinaryHash != binaryHash {
		return store.CodeAttestation{}, false
	}
	return r.Persisted(seKey), true
}

// ObserveCoverage advances only an existing exact-bound proof, never its APNs age.
func (t *Throttle) ObserveCoverage(seKey, version, token, nodeKey, binary string, at time.Time) (store.CodeAttestation, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok || seKey == "" || version == "" || token == "" || nodeKey == "" || binary == "" || r.BinaryHash != binary || r.Version != version || r.Token != token || r.NodeKey != nodeKey || r.At.After(at) {
		return store.CodeAttestation{}, false
	}
	if at.After(r.CoveredUntil) {
		r.CoveredUntil = at
		t.attested[seKey] = r
	}
	return r.Persisted(seKey), true
}
