package codeidentity

// beginLoop rotates exclusive loop ownership for one stable device identity.
// A registration loop and heartbeat rearm may overlap briefly, but only the
// latest generation can reserve a push.
func (t *deviceState) beginLoop(seKey string) uint64 {
	if seKey == "" {
		return 0
	}
	unlockReservation := t.lockPushReservation(seKey)
	defer unlockReservation()
	return t.beginLoopReservationHeld(seKey)
}

func (t *deviceState) beginLoopReservationHeld(seKey string) uint64 {
	generation := t.loopGeneration.Add(1)
	t.mu.Lock()
	t.loopGenerations[seKey] = generation
	delete(t.loopTokens, seKey)
	t.mu.Unlock()
	return generation
}

func (t *deviceState) loopCurrent(seKey string, generation uint64) bool {
	if seKey == "" || generation == 0 {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.loopGenerations[seKey] == generation
}

func (t *deviceState) endLoop(seKey string, generation uint64) {
	if seKey == "" || generation == 0 {
		return
	}
	t.mu.Lock()
	if t.loopGenerations[seKey] == generation {
		delete(t.loopGenerations, seKey)
		delete(t.loopTokens, seKey)
	}
	t.mu.Unlock()
}

func (t *deviceState) loopCurrentForToken(
	seKey, token string,
	generation uint64,
) bool {
	if seKey == "" || token == "" || generation == 0 {
		return false
	}
	tokenHash := codeAttestTokenHash(token)
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.loopGenerations[seKey] == generation &&
		t.loopTokens[seKey] == tokenHash
}

func (t *deviceState) lockPushReservation(seKey string) func() {
	t.mu.Lock()
	lock := t.reservationLocks[seKey]
	if lock == nil {
		lock = &reservationLock{}
		t.reservationLocks[seKey] = lock
	}
	lock.users++
	t.mu.Unlock()

	lock.mu.Lock()
	return func() {
		lock.mu.Unlock()
		t.mu.Lock()
		lock.users--
		if lock.users == 0 && t.reservationLocks[seKey] == lock {
			delete(t.reservationLocks, seKey)
		}
		t.mu.Unlock()
	}
}
