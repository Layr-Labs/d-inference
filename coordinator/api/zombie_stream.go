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

// zombieStreamCanceller throttles cancels sent for chunks that arrive for a
// request the coordinator no longer tracks (consumer gone / already settled).
// Such a stream burns provider GPU and token-budget admission until max_tokens,
// so the coordinator nudges the provider to stop — but at most once per
// throttle window per request.
type zombieStreamCanceller struct {
	mu   sync.Mutex
	sent map[string]time.Time
}

func newZombieStreamCanceller() *zombieStreamCanceller {
	return &zombieStreamCanceller{sent: make(map[string]time.Time)}
}

// shouldCancel reports whether to send a cancel for requestID now, recording
// the send. Returns false within zombieCancelThrottle of the last send for that
// id. Opportunistically sweeps expired entries so the map stays bounded.
func (z *zombieStreamCanceller) shouldCancel(requestID string, now time.Time) bool {
	z.mu.Lock()
	defer z.mu.Unlock()

	if t, ok := z.sent[requestID]; ok {
		if now.Sub(t) < zombieCancelThrottle {
			return false
		}
		delete(z.sent, requestID)
	}

	if len(z.sent) >= zombieCancelMaxEntries {
		var oldestID string
		var oldest time.Time
		for id, t := range z.sent {
			if now.Sub(t) > zombieCancelThrottle {
				delete(z.sent, id)
				continue
			}
			if oldestID == "" || t.Before(oldest) {
				oldestID = id
				oldest = t
			}
		}
		if len(z.sent) >= zombieCancelMaxEntries && oldestID != "" {
			delete(z.sent, oldestID)
		}
	}
	z.sent[requestID] = now
	return true
}
