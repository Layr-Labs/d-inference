package selection

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
)

// Affinity never changes the ordinary cost/load equivalence class. Reuse one
// hash and input buffer for the entire pool rather than allocating per machine.
func (r Ranking) affinityWinner(pool []Candidate, affinity string) int {
	const domain = "cache-affinity-v1"
	count, maxIDBytes := 0, 0
	winner := -1
	for i, candidate := range pool {
		if !r.equivalent(candidate) || !candidate.AffinityEligible {
			continue
		}
		count++
		winner = i
		maxIDBytes = max(maxIDBytes, len(candidate.ProviderID))
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
	winner = -1
	for i, candidate := range pool {
		if !r.equivalent(candidate) || !candidate.AffinityEligible {
			continue
		}
		id := candidate.ProviderID
		binary.BigEndian.PutUint32(input[prefixBytes-4:prefixBytes], uint32(len(id)))
		copy(input[prefixBytes:], id)
		hash.Reset()
		_, _ = hash.Write(input[:prefixBytes+len(id)])
		hash.Sum(score[:0])
		if winner < 0 || bytes.Compare(score[:], best[:]) > 0 {
			best, winner = score, i
		}
	}
	return winner
}
