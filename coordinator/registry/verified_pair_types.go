package registry

import (
	"errors"
	"time"
)

// This is coordinator membership authorization, not native readiness or key
// establishment. The caller must separately approve the proposed runtime,
// acquire each local canonical device gate and perform authenticated key
// establishment before inference-bearing traffic is permitted.
const VerifiedPairSuite = "aes256gcm-hkdf-sha256-v1"

const (
	verifiedPairPreparationLimit = 30 * time.Second
	verifiedPairLifetimeLimit    = 300 * time.Second
	verifiedPairHeartbeatLimit   = 30 * time.Second
	verifiedPairMaximumHeld      = 1024
)

var (
	ErrVerifiedPairInput       = errors.New("invalid verified pair request")
	ErrVerifiedPairUnavailable = errors.New("verified pair member unavailable")
	ErrVerifiedPairBusy        = errors.New("verified pair device already reserved")
	ErrVerifiedPairStale       = errors.New("verified pair handle or membership is stale")
	ErrVerifiedPairPhase       = errors.New("verified pair phase does not permit operation")
)

// ProposedRuntimeBindingSHA256 binds the caller's canonical native executable,
// capability, schedule, resource limits and transport selection. It is a
// proposal commitment, NEVER evidence that the coordinator approved that code.
type VerifiedPairRequest struct {
	Model                        string
	PlanSHA256                   [32]byte
	ProposedRuntimeBindingSHA256 [32]byte
	Lifetime                     time.Duration
}

type VerifiedPairPhase string

const (
	VerifiedPairPending     VerifiedPairPhase = "pending"
	VerifiedPairActive      VerifiedPairPhase = "active"
	VerifiedPairQuarantined VerifiedPairPhase = "quarantined"
	VerifiedPairReleased    VerifiedPairPhase = "released"
)

// The process key comes from the current registration AND its verified SE
// attestation. The release hashes come from current approved-release evidence,
// not provider-reported runtime flags or a proposed native capability.
type VerifiedPairMember struct {
	ProviderID              string
	DeviceSerial            string
	SEPublicKey             string
	ProcessPublicKey        string
	ProviderBinaryHash      string
	ProviderMetallibHash    string
	ReleasePolicyGeneration uint64
}

type VerifiedPairMembership struct {
	Epoch                        [16]byte
	Generation                   uint64
	Members                      [2]VerifiedPairMember // rank order, not lock order
	Model                        string
	PlanSHA256                   [32]byte
	ProposedRuntimeBindingSHA256 [32]byte
	Suite                        string
	PrepareBefore                time.Time
	ExpiresAt                    time.Time
	TranscriptSHA256             [32]byte
}

// A handle cannot be constructed outside this package, substituted by ID, or
// reused against another Registry. Copies refer to exactly one generation.
// Done closes on cancellation/expiry/quarantine/release; it never proves native
// cleanup. An active caller must stop admission and retain ownership on Done.
type VerifiedPairHandle struct {
	registry *Registry
	state    *verifiedPairState
}

func (h *VerifiedPairHandle) Done() <-chan struct{} {
	if h == nil || h.state == nil {
		ch := make(chan struct{})
		close(ch)
		return ch
	}
	return h.state.done
}

type VerifiedPairStatus struct {
	Membership VerifiedPairMembership
	Phase      VerifiedPairPhase
	Prepared   [2]bool
	Released   [2]bool
}

type verifiedPairState struct {
	membership VerifiedPairMembership
	providers  [2]*Provider
	untrust    [2]uint64
	phase      VerifiedPairPhase
	prepared   [2]bool
	released   [2]bool
	done       chan struct{}
	doneClosed bool
	timer      *time.Timer
}

// All indexes and state fields except the immutable Done channel are protected
// by Registry.mu. Physical serial AND SE keys remain held across reconnect when
// an active owner might still exist. There is deliberately no TTL that releases
// an uncertain active device, and no ID-only administrative clear method.
type verifiedPairRegistry struct {
	generation  uint64
	states      map[*verifiedPairState]struct{}
	connections map[*Provider]*verifiedPairState
	devices     map[string]*verifiedPairState
}
