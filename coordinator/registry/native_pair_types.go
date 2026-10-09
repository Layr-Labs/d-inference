package registry

import (
	"context"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const nativePairMaximumSessions = 64
const nativePairQueueFrames = 16
const nativePairQueueBytes = 1024 * 1024

// Opaque connection capability. Reconnect, a copied registration nonce, or an
// ID-only lookup cannot acquire another connection's session. Only Attach after
// the actual TLS member handshake creates this object; attestation is checked
// afresh by the real pair Registry when reserving/committing/using it.
type NativePairConnection struct {
	coordinator                       *NativePairCoordinator
	provider                          *Provider
	nonce                             string
	inboundSequence, outboundSequence uint64
	// admitted is set by Admit once the member's acknowledgement is queued.
	// Until then no selection, reservation or frame can use the connection.
	admitted bool
	closed   bool
	session  *NativePairSession
}
type NativePairSession struct {
	coordinator           *NativePairCoordinator
	handle                *VerifiedPairHandle
	membership            VerifiedPairMembership
	approval              nativeApprovedRuntime
	connections           [2]*NativePairConnection
	starts                [2]protocol.NativeAuthorizationStart
	hellos                [2][]byte
	confirmations         [2]bool
	committed             bool
	declined              bool // a member answered the prepare with a signed cancel before commit
	stopped               bool
	stoppedAt             time.Time // when admission closed; zero while running
	writersEnded          bool
	cancellationPublished bool // both terminal enqueue/close attempts completed
	writersStopped        chan struct{}
	queues                [2]chan []byte
	queuedBytes           [2]int // includes the one frame currently in the actual WS writer
	queuedFrames          [2]int
	ctx                   context.Context
	stop                  context.CancelFunc
	workers               sync.WaitGroup
}

// All mutable native session/control fields are protected by mu. Lock order is
// this mutex -> Registry.mu -> provider mutexes. No write/callback under mu.
// Native ownership is exclusively the existing Registry/owner lifecycle.
type NativePairCoordinator struct {
	mu          sync.Mutex
	registry    *Registry
	catalog     *NativeRuntimeCatalog
	revoked     map[string]bool
	connections map[*Provider]*NativePairConnection
	sessions    map[[16]byte]*NativePairSession
	closed      bool
	// formations is the pair selector's memory per registered cluster; nothing
	// is written to it unless RunFormation runs. formationWake coalesces
	// requests for a prompt selector pass.
	formations    map[nativePairFormationKey]*nativePairFormation
	formationWake chan struct{}
}

func NewNativePairCoordinator(r *Registry, c *NativeRuntimeCatalog) *NativePairCoordinator {
	if r == nil || c == nil || len(c.entries) == 0 {
		return nil
	}
	return &NativePairCoordinator{registry: r, catalog: c, revoked: make(map[string]bool), connections: make(map[*Provider]*NativePairConnection), sessions: make(map[[16]byte]*NativePairSession),
		formations: make(map[nativePairFormationKey]*nativePairFormation), formationWake: make(chan struct{}, 1)}
}

// Done means admission ended, never that native memory or device leases retired.
func (s *NativePairSession) Done() <-chan struct{} {
	if s == nil {
		return (*VerifiedPairHandle)(nil).Done()
	}
	return s.handle.Done()
}
func (s *NativePairSession) Cancel() {
	if s != nil {
		s.coordinator.Cancel(s)
	}
}

// WaitControlStopped joins only the two public-relay workers. Success is NOT
// evidence that the native owner cleaned up or released its canonical lease.
func (s *NativePairSession) WaitControlStopped(ctx context.Context) error {
	if s == nil {
		return ErrNativePairControl
	}
	select {
	case <-s.writersStopped:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
