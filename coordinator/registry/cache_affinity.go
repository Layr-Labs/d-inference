package registry

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
)

// Affinity never changes the ordinary cost/load equivalence class. Reuse one
// hash and input buffer for the entire pool rather than allocating per machine.
func cacheAffinityWinner(pool []*routingCandidate, equivalent func(*routingCandidate) bool, affinity string) *routingCandidate {
	const domain = "cache-affinity-v1"
	count, maxIDBytes := 0, 0
	var winner *routingCandidate
	for _, candidate := range pool {
		if !equivalent(candidate) || !candidate.cacheAffinityEligible {
			continue
		}
		count++
		winner = candidate
		maxIDBytes = max(maxIDBytes, len(candidate.provider.ID))
	}
	if count < 2 {
		return winner
	}
	hash := hmac.New(sha256.New, []byte(affinity))
	prefixBytes := 4 + len(domain) + 4
	input := make([]byte, prefixBytes+maxIDBytes)
	binary.BigEndian.PutUint32(input[:4], uint32(len(domain)))
	copy(input[4:], domain)
	var best, score [sha256.Size]byte
	winner = nil
	for _, candidate := range pool {
		if !equivalent(candidate) || !candidate.cacheAffinityEligible {
			continue
		}
		id := candidate.provider.ID
		binary.BigEndian.PutUint32(input[prefixBytes-4:prefixBytes], uint32(len(id)))
		copy(input[prefixBytes:], id)
		hash.Reset()
		_, _ = hash.Write(input[:prefixBytes+len(id)])
		hash.Sum(score[:0])
		if winner == nil || bytes.Compare(score[:], best[:]) > 0 {
			best, winner = score, candidate
		}
	}
	return winner
}
