package challenge

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// pendingChallenge tracks an outstanding challenge sent to a provider.
type pendingChallenge struct {
	nonce      string
	timestamp  string
	sentAt     time.Time
	responseCh chan *protocol.AttestationResponseMessage
}

// challengeTracker manages pending challenges for provider connections.
type challengeTracker struct {
	mu      sync.Mutex
	pending map[string]*pendingChallenge // keyed by nonce
}

func newChallengeTracker() *challengeTracker {
	return &challengeTracker{
		pending: make(map[string]*pendingChallenge),
	}
}

func (ct *challengeTracker) add(nonce string, pc *pendingChallenge) {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	ct.pending[nonce] = pc
}

func (ct *challengeTracker) remove(nonce string) *pendingChallenge {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	pc := ct.pending[nonce]
	delete(ct.pending, nonce)
	return pc
}

// Session owns the outstanding coordinator-generated nonces for one connection.
// Run and Deliver share this tracker; a new connection always receives a new one.
type Session struct {
	verifier *Verifier
	tracker  *challengeTracker
}

func (v *Verifier) NewSession() *Session {
	return &Session{verifier: v, tracker: newChallengeTracker()}
}
