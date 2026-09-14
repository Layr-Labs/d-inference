package codeidentity

// recordChallenge stores the nonce just pushed to a device so the read-loop
// delivery path can match the provider's reply — even one that lands on a
// different (re)connection from the same device (Fix 1). Overwrites any prior
// outstanding challenge for the device (only the latest push is honored).
func (t *deviceState) recordChallenge(seKey, nonce string) {
	if seKey == "" {
		return
	}
	t.mu.Lock()
	now := t.now()
	// Keep EVERY still-unexpired nonce, not just the latest: in alert mode the push
	// cooldown (75s) is shorter than the challenge validity (the APNs expiry window),
	// so a second challenge can be pushed while the first is still deliverable. If we
	// kept only the newest nonce, a delayed delivery of the first alert would make the
	// device reply with a nonce we had already discarded, we'd reject a valid proof,
	// and repeated delayed deliveries could strand attestation (Codex #8). Prune
	// expired entries on the way in so the slice stays bounded by validity/cooldown.
	old := t.outstanding[seKey]
	kept := make([]pushChallenge, 0, len(old)+1)
	for _, ch := range old {
		if now.Sub(ch.at) < t.challengeValidity {
			kept = append(kept, ch)
		}
	}
	t.outstanding[seKey] = append(kept, pushChallenge{nonce: nonce, at: now})
	t.mu.Unlock()
}

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

// outstandingChallenge reports whether the device has ANY still-valid pushed
// challenge, returning the most recent one. The delivery path matches a specific
// reply nonce via matchChallenge; this is the existence / most-recent view.
func (t *deviceState) outstandingChallenge(seKey string) (pushChallenge, bool) {
	if seKey == "" {
		return pushChallenge{}, false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	var best pushChallenge
	found := false
	for _, ch := range t.outstanding[seKey] {
		if now.Sub(ch.at) < t.challengeValidity && (!found || ch.at.After(best.at)) {
			best = ch
			found = true
		}
	}
	return best, found
}

// matchChallenge reports whether nonce equals ANY still-unexpired challenge pushed
// to this device. Accepting a reply to any in-flight challenge (not only the latest)
// is what prevents a delayed alert delivery from being rejected (Codex #8).
func (t *deviceState) matchChallenge(seKey, nonce string) bool {
	if seKey == "" || nonce == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	for _, ch := range t.outstanding[seKey] {
		if ch.nonce == nonce && now.Sub(ch.at) < t.challengeValidity {
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
