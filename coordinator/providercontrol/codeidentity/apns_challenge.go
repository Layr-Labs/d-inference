package codeidentity

func (t *deviceState) recordChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	now := t.now()
	old := t.outstanding[seKey]
	kept := old[:0]
	for _, challenge := range old {
		if now.Sub(challenge.at) < t.challengeValidity {
			kept = append(kept, challenge)
		}
	}
	t.outstanding[seKey] = append(kept, pushChallenge{
		nonce: nonce, at: now, token: token, nodeKey: nodeKey,
	})
	t.mu.Unlock()
}

func (t *deviceState) matchChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	for _, challenge := range t.outstanding[seKey] {
		if challenge.nonce == nonce &&
			now.Sub(challenge.at) < t.challengeValidity &&
			(challenge.token == "" || challenge.token == token) &&
			(challenge.nodeKey == "" || challenge.nodeKey == nodeKey) {
			return true
		}
	}
	return false
}

func (t *deviceState) consumeChallengeForIdentity(
	seKey, nonce, token, nodeKey string,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	challenges := t.outstanding[seKey]
	for i, challenge := range challenges {
		if challenge.nonce == nonce &&
			now.Sub(challenge.at) < t.challengeValidity &&
			(challenge.token == "" || challenge.token == token) &&
			(challenge.nodeKey == "" || challenge.nodeKey == nodeKey) {
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

// clearChallengeIf removes the given nonce from the device's outstanding set (e.g.
// after it was answered or its push failed), leaving any other in-flight nonces
// intact so a concurrent challenge is never clobbered.
func (t *deviceState) clearChallengeIf(seKey, nonce string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	if chs, ok := t.outstanding[seKey]; ok {
		kept := chs[:0]
		for _, ch := range chs {
			if ch.nonce != nonce {
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
func (t *deviceState) clearChallenge(seKey string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	delete(t.outstanding, seKey)
	t.mu.Unlock()
}
