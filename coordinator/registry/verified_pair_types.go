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
	// verifiedPairMemberPreparationLimit is the longest preparation window a
	// member accepts. It measures the window as PrepareBefore minus its own
	// wall clock when the prepare frame arrives, and drops the connection when
	// that exceeds this limit (NativePairMemberSession). It is the provider's
	// constant, mirrored here; the two must change together.
	verifiedPairMemberPreparationLimit = 30 * time.Second
	// verifiedPairPreparationLimit is the window the coordinator grants. It is
	// five seconds short of the member's limit, so a member whose clock trails
	// the coordinator's by up to five seconds plus the frame's transit time
	// still measures a window it accepts.
	verifiedPairPreparationLimit = 25 * time.Second
	verifiedPairLifetimeLimit    = 300 * time.Second
	verifiedPairHeartbeatLimit   = 30 * time.Second
	verifiedPairMaximumHeld      = 1024
	// verifiedPairOwnerRetirementLimit bounds how long an owner started under a
	// reservation can outlive its ExpiresAt. The member anchors the fixed
	// lifetime to its own clock when the prepare frame arrives, so its deadline
	// trails ExpiresAt by however far its clock is behind. A member accepts the
	// frame only if it measures at most verifiedPairMemberPreparationLimit to
	// prepare, which allows a clock behind by the granted window's shortfall
	// plus the transit time, and a pair commits only before PrepareBefore, so
	// the transit time is under the granted window. The two add up to less
	// than the member's limit whatever window is granted. Native cleanup then
	// has three seconds (NativePairMemberSession.cleanupDeadline); the rest is
	// slack.
	verifiedPairOwnerRetirementLimit = verifiedPairMemberPreparationLimit + 10*time.Second
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
	// departed marks a member whose original connection left the registry
	// after commit: its owner-release receipt can never arrive.
	departed [2]bool
	// account is the one account both members belonged to when the pair was
	// reserved, or empty when they did not share one. Immutable.
	account string
	// keysRelayed is set once the relay accepted both members' key
	// confirmations for delivery: the earliest a leader can be serving.
	keysRelayed bool
	done        chan struct{}
	doneClosed  bool
	timer       *time.Timer
}

// All indexes and state fields except the immutable Done channel are protected
// by Registry.mu. Physical serial AND SE keys remain held across reconnect
// while an owner might still exist: until both authenticated owner-release
// receipts arrive, or, for a member whose original connection is gone, until
// the reservation's fixed lifetime and the owner retirement limit have passed
// (releaseAbandonedQuarantineLocked). No TTL releases a member that is still
// connected, and there is no ID-only administrative clear method.
type verifiedPairRegistry struct {
	generation  uint64
	states      map[*verifiedPairState]struct{}
	connections map[*Provider]*verifiedPairState
	devices     map[string]*verifiedPairState
}
