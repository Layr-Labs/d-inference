package identity

import (
	"time"
)

func (t *Throttle) RecordResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) <-chan struct{} {
	t.mu.Lock()
	done := make(chan struct{})
	t.resumeChallenges[nonce] = resumeChallenge{
		ProviderID: providerID, NodeKey: nodeKey, SeKey: seKey,
		Token: token, ExpiresAt: t.Now().Add(t.ResumeTimeout), Done: done,
	}
	t.mu.Unlock()
	return done
}

func (t *Throttle) ClearResumeChallenges(providerID string) {
	t.mu.Lock()
	for nonce, challenge := range t.resumeChallenges {
		if challenge.ProviderID == providerID {
			close(challenge.Done)
			delete(t.resumeChallenges, nonce)
		}
	}
	t.mu.Unlock()
}

func resumeChallengeMatches(
	challenge resumeChallenge,
	providerID, nodeKey, seKey, token string,
) bool {
	return challenge.ProviderID == providerID &&
		challenge.NodeKey == nodeKey &&
		challenge.SeKey == seKey &&
		challenge.Token == token
}

func (t *Throttle) ResumeChallengeExpiry(
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
	return challenge.ExpiresAt, true
}

func (t *Throttle) MatchResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	return ok &&
		t.Now().Before(challenge.ExpiresAt) &&
		resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token)
}

func (t *Throttle) ConsumeResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok ||
		!t.Now().Before(challenge.ExpiresAt) ||
		!resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token) {
		return false
	}
	delete(t.resumeChallenges, nonce)
	close(challenge.Done)
	return true
}

// expireResumeChallenge atomically lets only the deadline path claim a resume
// nonce. A response racing the timer either consumes the still-live nonce first
// or loses to this removal; neither path can both grant proof and start APNs.
func (t *Throttle) ExpireResumeChallenge(
	nonce, providerID, nodeKey, seKey, token string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	challenge, ok := t.resumeChallenges[nonce]
	if !ok ||
		t.Now().Before(challenge.ExpiresAt) ||
		!resumeChallengeMatches(challenge, providerID, nodeKey, seKey, token) {
		return false
	}
	delete(t.resumeChallenges, nonce)
	close(challenge.Done)
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
