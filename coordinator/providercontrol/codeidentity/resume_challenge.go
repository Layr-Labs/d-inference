package codeidentity

import (
	"time"
)

// recordResumeChallenge stores a one-time, connection-bound X25519 PoP nonce
// with the exact resume deadline. APNs challenges intentionally use the longer
// challengeValidity window; live-connection resume proofs do not.
func (t *deviceState) recordResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) <-chan struct{} {
	t.mu.Lock()
	done := make(chan struct{})
	t.resumeChallenges[nonce] = resumeChallenge{
		providerID: providerID, nodeKey: nodeKey, seKey: seKey,
		token: token, expiresAt: t.now().Add(t.resumeTimeout), done: done,
	}
	t.mu.Unlock()
	return done
}

func (t *deviceState) clearResumeChallenges(providerID string) {
	t.mu.Lock()
	for nonce, challenge := range t.resumeChallenges {
		if challenge.providerID == providerID {
			close(challenge.done)
			delete(t.resumeChallenges, nonce)
		}
	}
	t.mu.Unlock()
}

func resumeChallengeMatches(
	challenge resumeChallenge,
	providerID, nodeKey, seKey, token string,
) bool {
	return challenge.providerID == providerID &&
		challenge.nodeKey == nodeKey &&
		challenge.seKey == seKey &&
		challenge.token == token
}

func (t *deviceState) resumeChallengeExpiry(
	nonce, providerID, nodeKey, seKey, token string,
) (time.Time, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok || !resumeChallengeMatches(
		challenge, providerID, nodeKey, seKey, token,
	) {
		return time.Time{}, false
	}
	return challenge.expiresAt, true
}

func (t *deviceState) matchResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	return ok &&
		t.now().Before(challenge.expiresAt) &&
		resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token)
}

func (t *deviceState) consumeResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok ||
		!t.now().Before(challenge.expiresAt) ||
		!resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token) {
		return false
	}
	delete(t.resumeChallenges, nonce)
	close(challenge.done)
	return true
}

// expireResumeChallenge atomically lets only the deadline path claim a resume
// nonce. A response racing the timer either consumes the still-live nonce first
// or loses to this removal; neither path can both grant proof and start APNs.
func (t *deviceState) expireResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok ||
		t.now().Before(challenge.expiresAt) ||
		!resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token) {
		return false
	}
	delete(t.resumeChallenges, nonce)
	close(challenge.done)
	return true
}
