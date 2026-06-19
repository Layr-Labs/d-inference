package api

import (
	"sync"
	"time"
)

// zombieCancelThrottle bounds how often the coordinator re-sends a cancel for
// the same abandoned (unknown) request. A zombie stream emits ~1 chunk per
// token, so cancelling on every chunk would flood the provider with WS writes;
// one cancel per request per this interval is enough to stop a provider that's
// actually listening, and harmless against one that isn't.
const zombieCancelThrottle = 10 * time.Second
const zombieCancelMaxEntries = 4096
const zombieCancelForceReconnectAttempts = 3

type zombieCancelRecord struct {
	last     time.Time
	attempts int
}

type zombieCancelAction struct {
	sendCancel     bool
	forceReconnect bool
}

// zombieStreamCanceller throttles cancels sent for chunks that arrive for a
// request the coordinator no longer tracks (consumer gone / already settled).
// Such a stream burns provider GPU and token-budget admission until max_tokens,
// so the coordinator nudges the provider to stop — but at most once per
// throttle window per request.
type zombieStreamCanceller struct {
	mu   sync.Mutex
	sent map[string]zombieCancelRecord
}

func newZombieStreamCanceller() *zombieStreamCanceller {
	return &zombieStreamCanceller{sent: make(map[string]zombieCancelRecord)}
}

// record records an unknown-request chunk and returns what recovery action the
// caller should take. After repeated throttled cancel attempts, forceReconnect
// asks the caller to cycle the provider connection: either the provider never
// received our cancels or its generation loop ignored them, and letting it run
// to max_tokens burns fleet capacity.
func (z *zombieStreamCanceller) record(requestID string, now time.Time) zombieCancelAction {
	z.mu.Lock()
	defer z.mu.Unlock()

	rec, ok := z.sent[requestID]
	if ok {
		if now.Sub(rec.last) < zombieCancelThrottle {
			return zombieCancelAction{}
		}
	}

	if !ok && len(z.sent) >= zombieCancelMaxEntries {
		var oldestID string
		var oldest zombieCancelRecord
		for id, rec := range z.sent {
			if now.Sub(rec.last) > zombieCancelThrottle {
				delete(z.sent, id)
				continue
			}
			if oldestID == "" || rec.last.Before(oldest.last) {
				oldestID = id
				oldest = rec
			}
		}
		if len(z.sent) >= zombieCancelMaxEntries && oldestID != "" {
			delete(z.sent, oldestID)
		}
	}

	rec.last = now
	rec.attempts++
	z.sent[requestID] = rec
	return zombieCancelAction{
		sendCancel:     true,
		forceReconnect: rec.attempts >= zombieCancelForceReconnectAttempts,
	}
}
