package identity

import (
	"crypto/sha256"
	"strings"
)

// PublicationGeneration captures the erasure boundary before proof validation
// or a store read. A later Forget rejects only publications for the erased keys.
func (t *Throttle) PublicationGeneration() uint64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.publicationGeneration
}

func (t *Throttle) publicationCurrentLocked(seKey string, generation uint64) bool {
	return t.forgotten[sha256.Sum256([]byte(seKey))] <= generation
}

// Forget drops runtime identity data for the already filtered, unshared keys.
// Hash-only generation fences prevent an in-flight reply or startup read from
// restoring it; a fresh challenge for a new legitimate owner can still proceed.
func (t *Throttle) Forget(seKeys []string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, seKey := range seKeys {
		if seKey == "" {
			continue
		}
		t.publicationGeneration++
		t.forgotten[sha256.Sum256([]byte(seKey))] = t.publicationGeneration
		delete(t.attested, seKey)
		delete(t.outstanding, seKey)
		delete(t.loopGenerations, seKey)
		delete(t.loopTokens, seKey)
		delete(t.lastBudgetClear, seKey)
		delete(t.novelTokenBlockedUntil, seKey)
		delete(t.novelPushFloor, seKey)
		delete(t.budgetTokenOrder, seKey)
		for key := range t.lastPush {
			if key == seKey || strings.HasPrefix(key, seKey+"\x00") {
				delete(t.lastPush, key)
			}
		}
		for key := range t.durableNextPush {
			if key == seKey || strings.HasPrefix(key, seKey+"\x00") {
				delete(t.durableNextPush, key)
			}
		}
		for nonce, challenge := range t.resumeChallenges {
			if challenge.SeKey == seKey {
				close(challenge.Done)
				delete(t.resumeChallenges, nonce)
			}
		}
	}
}
