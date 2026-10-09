package registry

import (
	"encoding/hex"
	"sort"
	"time"
)

// NativePairState is where a registered cluster stands with the coordinator.
type NativePairState string

const (
	// NativePairStateWaiting: no session; Waiting says why.
	NativePairStateWaiting NativePairState = "waiting"
	// NativePairStatePreparing: both devices are held and members are preparing;
	// no owner may start yet.
	NativePairStatePreparing NativePairState = "preparing"
	// NativePairStateActive: owners were authorized to start. This is not
	// serving readiness: key establishment and model load follow, and
	// NativePairView.ServingReady reports when they are done.
	NativePairStateActive NativePairState = "active"
	// NativePairStateReforming: the cluster's last session was committed and
	// has ended, by its fixed lifetime or otherwise, and the coordinator forms
	// the next one as soon as both devices are released. Waiting says what it
	// still waits for.
	NativePairStateReforming NativePairState = "reforming"
)

// nativePairExpectedCleanup is how long a healthy member takes to clean up
// after its session is cancelled and to report it: the provider's own cleanup
// deadline is three seconds. It only feeds the ReformExpectedAt estimate.
const nativePairExpectedCleanup = 5 * time.Second

// NativePairMemberView is one rank of a registered cluster. Attached is false
// when no connection currently claims that rank.
type NativePairMemberView struct {
	Attached     bool
	ProviderID   string
	SerialNumber string
	ChipName     string
	MemoryGB     int
}

// NativePairView is what listings report for one registered cluster: enough
// for an owner-facing card without exposing another account's members.
type NativePairView struct {
	AccountID    string
	ClusterID    string
	PolicySHA256 string
	ApprovalID   string
	Model        string
	State        NativePairState
	Waiting      NativePairWaiting
	Members      [2]NativePairMemberView // rank order: leader, follower
	// ServingReady is true while a request from the pair's account would be
	// handed to the leader now: the session is active, both key confirmations
	// were relayed, the leader reports the model loaded and is not draining,
	// and requests are routed to pairs at all. Concurrency and the lifetime a
	// particular request needs are decided per request.
	ServingReady bool
	// Epoch, PrepareBefore and ExpiresAt describe the current session; zero
	// while waiting.
	Epoch         string
	PrepareBefore time.Time
	ExpiresAt     time.Time
	// ReformExpectedAt is set while reforming: the coordinator's estimate of
	// when both members will have reported cleanup, at which point it starts
	// the next session. It is an estimate, and serving resumes only after that
	// session's preparation, key exchange and model load.
	ReformExpectedAt time.Time
	// Failures counts consecutive sessions that stopped before commit without
	// a member declining; Declines counts consecutive preparations a member
	// declined with a signed cancel. RetryAt is when the next attempt is
	// allowed after either.
	Failures int
	Declines int
	RetryAt  time.Time
}

// Pairs reports every cluster a member registered on an attached connection,
// ordered by account and cluster. A nil coordinator reports none.
func (c *NativePairCoordinator) Pairs() []NativePairView {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	views := make(map[nativePairFormationKey]*NativePairView)
	view := func(key nativePairFormationKey) *NativePairView {
		v := views[key]
		if v == nil {
			v = &NativePairView{AccountID: key.account, ClusterID: key.cluster, PolicySHA256: key.policy,
				State: NativePairStateWaiting, Waiting: NativePairWaitingPeer}
			views[key] = v
		}
		return v
	}
	for provider, connection := range c.connections {
		membership := provider.clusterMembership
		if membership == nil || !c.validConnectionLocked(connection) {
			continue
		}
		provider.mu.Lock()
		account := provider.AccountID
		member := NativePairMemberView{Attached: true, ProviderID: provider.ID,
			ChipName: provider.Hardware.ChipName, MemoryGB: provider.Hardware.MemoryGB}
		if provider.AttestationResult != nil {
			member.SerialNumber = provider.AttestationResult.SerialNumber
		}
		provider.mu.Unlock()
		if account == "" {
			continue
		}
		v := view(nativePairFormationKey{account: account, cluster: membership.ClusterID, policy: membership.PolicySHA256})
		if !v.Members[membership.Rank].Attached {
			v.Members[membership.Rank] = member
		}
	}
	for key, formation := range c.formations {
		v := view(key)
		v.ApprovalID, v.Model, v.Waiting = formation.approval, formation.model, formation.waiting
		v.Failures, v.Declines, v.RetryAt = formation.failures, formation.declines, formation.notBefore
		session, reformingSince := formation.session, formation.reformingSince
		if session != nil && !session.stopped {
			v.Waiting = NativePairWaitingNone
			v.Epoch = hex.EncodeToString(session.membership.Epoch[:])
			v.PrepareBefore, v.ExpiresAt = session.membership.PrepareBefore, session.membership.ExpiresAt
			v.State = NativePairStatePreparing
			if session.committed {
				v.State = NativePairStateActive
				v.ServingReady = c.registry.verifiedPairServingReady(session.handle)
			}
			continue
		}
		if session != nil {
			// Admission is closed and the selector has not settled the session
			// yet. Until the registry releases both devices the cluster waits
			// on that hold, exactly as the selector reports it on its next pass.
			if !c.sessionReleasedLocked(session) {
				v.Waiting = NativePairWaitingHeld
			}
			reformingSince = time.Time{}
			if session.committed {
				reformingSince = session.stoppedAt
			}
		}
		// A committed session ended and nothing but the devices' release, or
		// the selector's next pass, stands between the cluster and its next one.
		if !reformingSince.IsZero() && (v.Waiting == NativePairWaitingHeld || v.Waiting == NativePairWaitingNone) {
			v.State, v.ReformExpectedAt = NativePairStateReforming, reformingSince.Add(nativePairExpectedCleanup)
		}
	}
	out := make([]NativePairView, 0, len(views))
	for _, v := range views {
		out = append(out, *v)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].AccountID != out[j].AccountID {
			return out[i].AccountID < out[j].AccountID
		}
		if out[i].ClusterID != out[j].ClusterID {
			return out[i].ClusterID < out[j].ClusterID
		}
		return out[i].PolicySHA256 < out[j].PolicySHA256
	})
	return out
}
