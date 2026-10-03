package trust

import (
	"time"
)

func (t *codeAttestThrottle) recordResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) <-chan struct{} {
	t.mu.Lock()
	done := make(chan struct{})
	t.resumeChallenges[nonce] = codeAttestResumeChallenge{
		providerID: providerID, nodeKey: nodeKey, seKey: seKey,
		token: token, expiresAt: t.now().Add(t.resumeTimeout), done: done,
	}
	t.mu.Unlock()
	return done
}

func (t *codeAttestThrottle) clearResumeChallenges(providerID string) {
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
	challenge codeAttestResumeChallenge,
	providerID, nodeKey, seKey, token string,
) bool {
	return challenge.providerID == providerID &&
		challenge.nodeKey == nodeKey &&
		challenge.seKey == seKey &&
		challenge.token == token
}

func (t *codeAttestThrottle) resumeChallengeExpiry(
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

func (t *codeAttestThrottle) matchResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	return ok &&
		t.now().Before(challenge.expiresAt) &&
		resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token)
}

func (t *codeAttestThrottle) consumeResumeChallenge(
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
func (t *codeAttestThrottle) expireResumeChallenge(
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

// persistCodeAttestation best-effort writes a successful code-identity round-trip
// to the store so it survives a coordinator restart/deploy (W5 Fix 2). It mirrors
// the in-memory recordAttested and is called from the same event
// (HandleCodeAttestationResponse). Behind the store seam (no-op until
// SeedCodeAttestCache wires a store): prod runs the Postgres store, so this makes
// reuse durable across blue-green deploys (avoiding a fleet-wide re-push storm).
// Runs off the read loop (saferun.Go) so the DB write never stalls WebSocket
// reads. SECURITY: writes only AFTER the full nonce-match + SE-signature
// verification — never from an unverified heartbeat token.
