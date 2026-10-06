package identity

func (t *Throttle) RecordChallengeForIdentity(
	generation uint64,
	seKey, nonce, token, nodeKey string,
) bool {
	if seKey == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.publicationCurrentLocked(seKey, generation) {
		return false
	}
	now := t.Now()
	old := t.outstanding[seKey]
	kept := old[:0]
	for _, challenge := range old {
		if now.Sub(challenge.At) < t.ChallengeValidity {
			kept = append(kept, challenge)
		}
	}
	t.outstanding[seKey] = append(kept, pushChallenge{
		Nonce: nonce, At: now, Token: token, NodeKey: nodeKey,
	})
	return true
}

func (t *Throttle) MatchChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) bool {
	_, ok := t.ChallengeForIdentity(seKey, nonce, token, nodeKey)
	return ok
}

// ChallengeForIdentity identifies the live nonce accepted by the proof matcher.
func (t *Throttle) ChallengeForIdentity(seKey, nonce, token, nodeKey string) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.Now()
	for _, challenge := range t.outstanding[seKey] {
		if challenge.Nonce == nonce &&
			now.Sub(challenge.At) < t.ChallengeValidity &&
			(challenge.Token == "" || challenge.Token == token) &&
			(challenge.NodeKey == "" || challenge.NodeKey == nodeKey) {
			return challenge.Nonce, true
		}
	}
	return "", false
}

func (t *Throttle) ConsumeChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.Now()
	challenges := t.outstanding[seKey]
	for i, challenge := range challenges {
		if challenge.Nonce == nonce &&
			now.Sub(challenge.At) < t.ChallengeValidity &&
			(challenge.Token == "" || challenge.Token == token) &&
			(challenge.NodeKey == "" || challenge.NodeKey == nodeKey) {
			challenges = append(challenges[:i], challenges[i+1:]...)
			if len(challenges) == 0 {
				delete(t.outstanding, seKey)
			} else {
				t.outstanding[seKey] = challenges
			}
			return true
		}
	}
	return false
}

// markChallengeAccepted records that APNs accepted the push carrying nonce.
func (t *Throttle) MarkChallengeAccepted(seKey, nonce string, generation uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for i := range t.outstanding[seKey] {
		if t.outstanding[seKey][i].Nonce == nonce {
			t.outstanding[seKey][i].Accepted = true
			t.outstanding[seKey][i].LoopGeneration = generation
		}
	}
}

// takeUnansweredPushes counts this device's APNs-accepted pushes that no
// verified reply consumed and no earlier call counted, and marks them
// counted. Outstanding challenges outlive a connection, so a reconnected
// provider's loop still counts the previous connection's push. Call it
// before recording the next challenge, which prunes expired ones.
func (t *Throttle) TakeUnansweredPushes(seKey string, generation ...uint64) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	n := 0
	for i := range t.outstanding[seKey] {
		if c := &t.outstanding[seKey][i]; c.Accepted && !c.Counted &&
			(len(generation) == 0 || c.LoopGeneration == generation[0]) {
			c.Counted = true
			n++
		}
	}
	return n
}

// clearChallengeIf removes the given nonce from the device's outstanding set (e.g.
// after it was answered or its push failed), leaving any other in-flight nonces
// intact so a concurrent challenge is never clobbered.
func (t *Throttle) ClearChallengeIf(seKey, nonce string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	if chs, ok := t.outstanding[seKey]; ok {
		kept := chs[:0]
		for _, ch := range chs {
			if ch.Nonce != nonce {
				kept = append(kept, ch)
			}
		}
		if len(kept) == 0 {
			delete(t.outstanding, seKey)
		} else {
			t.outstanding[seKey] = kept
		}
	}
	t.mu.Unlock()
}

// clearChallenge unconditionally drops any outstanding challenge for a device.
// Used on APNs token rotation so a stale reply to the OLD-token challenge can
// never complete the forced re-challenge: if the fresh push is delayed or fails,
// there is simply no outstanding nonce to match (fail-closed), rather than the
// pre-rotation nonce remaining answerable. The subsequent fresh push records its
// own nonce, so this never clobbers the new challenge (it runs before the push).
func (t *Throttle) ClearChallenge(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	delete(t.outstanding, seKey)
	t.mu.Unlock()
}

// SeedCodeAttestCache wires the store into the code-identity reuse cache and
// seeds it from persisted records at startup (W5 Fix 2). This is what makes the
// reuse cache survive a coordinator restart / blue-green deploy, so a fresh
// instance does not re-push the entire fleet (against Apple's ~3/hour/device push
// budget). Safe to call once during server setup, AFTER the store is set and the
// attestor is wired; a nil store or nil throttle is a no-op. SECURITY: seeding
// only repopulates the cache that reuseAttestation re-validates (same version,
// freshness, token, and exact process key) on every read. A stale, mismatched,
// or legacy process-key-less row still falls through to a real challenge.
