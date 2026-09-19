package registry

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
)

// accountAffinityScore is an unweighted rendezvous rank. Live load, session
// IDs, API-key IDs, request IDs and prompts deliberately do not enter it. A
// machine joining/leaving cannot reorder any two existing physical machines.
// Length framing prevents ambiguous concatenations of account/model/identity.
func accountAffinityScore(account, model string, identity accountAffinityIdentity) [sha256.Size]byte {
	h := sha256.New()
	_, _ = h.Write([]byte("darkbloom/account-affinity/v1\x00"))
	var length [8]byte
	for _, part := range [...]string{account, model} {
		binary.BigEndian.PutUint64(length[:], uint64(len(part)))
		_, _ = h.Write(length[:])
		_, _ = h.Write([]byte(part))
	}
	// Feed the namespaced identity without allocating its concatenation.
	// Legacy serial/key ranks remain byte-for-byte identical; verified
	// inventory IDs use their own "machine:" namespace.
	prefix := identity.prefix()
	binary.BigEndian.PutUint64(length[:], uint64(len(prefix))+uint64(len(identity.value)))
	_, _ = h.Write(length[:])
	_, _ = h.Write([]byte(prefix))
	_, _ = h.Write([]byte(identity.value))
	var score [sha256.Size]byte
	h.Sum(score[:0])
	return score
}

// accountAffinityCandidateBefore compares already-ranked candidates. A digest
// collision is broken by physical identity. Multiple live sessions of the same
// machine share a rank; only that same-machine tie uses the connection ID.
func accountAffinityCandidateBefore(a, b *routingCandidate) bool {
	if order := bytes.Compare(a.accountAffinityScore[:], b.accountAffinityScore[:]); order != 0 {
		return order > 0
	}
	if a.snapshot.affinityIdentity != b.snapshot.affinityIdentity {
		return a.snapshot.affinityIdentity.before(b.snapshot.affinityIdentity)
	}
	if a.provider == nil || b.provider == nil {
		return a.provider != nil
	}
	return a.provider.ID < b.provider.ID
}
