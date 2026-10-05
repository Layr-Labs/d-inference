// Package input owns bounded, sanitized admission to an App Attest inbox.
package input

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Admission serializes offers with shutdown. The caller owns the inbox and the
// evidence-gap callback, which must fence authorization before Offer returns.
type Admission struct {
	mu     sync.Mutex
	closed bool
}

func (a *Admission) Close() {
	a.mu.Lock()
	a.closed = true
	a.mu.Unlock()
}

func (a *Admission) Offer(p protocol.AppAttestShadowPayload, inbox chan<- protocol.AppAttestShadowPayload, dropped func()) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		dropped()
		return
	}
	// Runtime diagnostics are optional context: invalid values are stripped,
	// never a reason to drop the frame or fence a lease.
	p.SanitizeRuntimeDiagnostics(time.Now())
	// Length bounds also cover decode-only fields; oversized proofs never queue.
	if len(p.Action) > 32 || len(p.Environment) > 32 || len(p.AccountScope) > 64 || len(p.EnrollmentSession) > 64 || len(p.KeyID) > 64 || len(p.Challenge) > 64 || len(p.Session) > 64 || len(p.Proof) > 44*1024 || len(p.Result) > 64 {
		dropped()
		return
	}
	if !p.AppleError.Valid() || !p.ValidClientDiagnostics() || (p.Status != nil && len(p.Status.AttestationPublicKey) > 128) {
		dropped()
		return
	}
	for _, value := range append(p.Status.Values(), p.Status.HardwareValues()...) {
		if len(value) > 128 {
			dropped()
			return
		}
	}
	select {
	case inbox <- p:
	default:
		dropped()
	}
}
