package registry

import (
	"context"
	"encoding/hex"
	"time"
)

// Pair formation is the coordinator's own selector: the production caller of
// Reserve. It pairs two attached member connections that belong to one account
// and registered the same cluster label, the same installed policy and the two
// distinct ranks. It adds no authority of its own. Reserve still performs the
// atomic bilateral device hold and every identity, trust, release and idleness
// check; the selector only decides which two connections to offer it, and when.
const (
	nativePairFormationInterval   = time.Second
	nativePairFormationRetryFloor = 2 * time.Second
	nativePairFormationRetryLimit = time.Minute
	// A member that declines a preparation answered deliberately: its build
	// cannot serve a committed start yet, and asking again soon changes
	// nothing. Each offer also costs the member one of the 1,024 session
	// epochs its control remembers per process, so repeated declines are
	// spaced far wider than failures: at this ceiling a member process is
	// offered about four pairs an hour, and its memory lasts over ten days.
	nativePairDeclineRetryFloor = 30 * time.Second
	nativePairDeclineRetryLimit = 15 * time.Minute
)

// A cluster is identified by what both members registered, scoped to the
// account that owns them. No member can name a peer or another account.
type nativePairFormationKey struct {
	account, cluster, policy string
}

// nativePairFormation is the selector's memory of one cluster. Guarded by the
// coordinator mutex.
type nativePairFormation struct {
	session   *NativePairSession // the session this selector last formed, until it stops
	approval  string
	model     string
	failures  int               // consecutive sessions that stopped before owners were committed, undeclined
	declines  int               // consecutive preparations a member declined
	notBefore time.Time         // earliest next attempt after a failure or a decline
	backoff   NativePairWaiting // which of the two notBefore waits for
	waiting   NativePairWaiting
	// reformingSince is when the last committed session stopped; zero when the
	// cluster's last session never committed or a new one has been formed.
	reformingSince time.Time
}

// NativePairWaiting says why a cluster has no session right now.
type NativePairWaiting string

const (
	NativePairWaitingNone       NativePairWaiting = ""
	NativePairWaitingPeer       NativePairWaiting = "peer_absent"   // one rank is not attached, or a rank is claimed twice
	NativePairWaitingApproval   NativePairWaiting = "no_approval"   // no current catalog entry matches the registered policy and model
	NativePairWaitingHeld       NativePairWaiting = "device_held"   // a previous pair still holds a device
	NativePairWaitingIneligible NativePairWaiting = "not_eligible"  // a member fails the pair identity, trust or idleness gates
	NativePairWaitingRetry      NativePairWaiting = "retry_backoff" // the last attempt stopped before commit
	// NativePairWaitingDeclined: a member answered the last preparation with a
	// signed cancel. Both members are present and answering; the cluster is
	// offered again after a long delay.
	NativePairWaitingDeclined NativePairWaiting = "member_declined"
)

type nativePairFormationCandidate struct {
	key         nativePairFormationKey
	connections [2]*NativePairConnection
	models      [2]map[string]bool
	chips       [2]string
	complete    bool
}

// RunFormation runs the selector until ctx ends. It is started only when an
// approval catalog is configured; a nil coordinator returns at once.
func (c *NativePairCoordinator) RunFormation(ctx context.Context) {
	if c == nil {
		return
	}
	ticker := time.NewTicker(nativePairFormationInterval)
	defer ticker.Stop()
	for {
		c.formPairs(time.Now())
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-c.formationWake:
		}
	}
}

// wakeFormation asks the selector for a prompt pass. It never blocks.
func (c *NativePairCoordinator) wakeFormation() {
	select {
	case c.formationWake <- struct{}{}:
	default:
	}
}

// formPairs is one selector pass. It holds the coordinator mutex only to read
// and record selector state; Reserve takes its own locks.
func (c *NativePairCoordinator) formPairs(now time.Time) {
	for _, candidate := range c.formationCandidates(now) {
		c.formPair(candidate, now)
	}
}

// formationCandidates settles finished sessions, forgets clusters with no
// attached member, and returns the clusters that have no session.
func (c *NativePairCoordinator) formationCandidates(now time.Time) []nativePairFormationCandidate {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.removeReleasedSessionsLocked()
	present := make(map[nativePairFormationKey]*nativePairFormationCandidate)
	for provider, connection := range c.connections {
		membership := provider.clusterMembership
		if membership == nil || !c.validConnectionLocked(connection) {
			continue
		}
		provider.mu.Lock()
		account, chip := provider.AccountID, provider.Hardware.ChipName
		models := make(map[string]bool, len(provider.Models))
		for _, model := range provider.Models {
			models[model.ID] = true
		}
		provider.mu.Unlock()
		if account == "" {
			continue
		}
		key := nativePairFormationKey{account: account, cluster: membership.ClusterID, policy: membership.PolicySHA256}
		candidate := present[key]
		if candidate == nil {
			candidate = &nativePairFormationCandidate{key: key, complete: true}
			present[key] = candidate
		}
		if candidate.connections[membership.Rank] != nil {
			// Two connections claim one rank: never guess which is genuine.
			candidate.complete = false
			continue
		}
		candidate.connections[membership.Rank] = connection
		candidate.models[membership.Rank] = models
		candidate.chips[membership.Rank] = chip
	}
	for key, formation := range c.formations {
		if formation.session != nil && formation.session.stopped {
			switch {
			case formation.session.committed:
				formation.reformingSince = formation.session.stoppedAt
			case formation.session.declined:
				formation.declines++
				formation.backoff = NativePairWaitingDeclined
				formation.notBefore = now.Add(nativePairBackoff(formation.declines, nativePairDeclineRetryFloor, nativePairDeclineRetryLimit))
			default:
				formation.failures++
				formation.backoff = NativePairWaitingRetry
				formation.notBefore = now.Add(nativePairBackoff(formation.failures, nativePairFormationRetryFloor, nativePairFormationRetryLimit))
			}
			formation.session = nil
		}
		if formation.session == nil && present[key] == nil {
			delete(c.formations, key)
		}
	}
	var candidates []nativePairFormationCandidate
	for key, candidate := range present {
		formation := c.formations[key]
		if formation == nil {
			formation = &nativePairFormation{}
			c.formations[key] = formation
		}
		if formation.session != nil {
			continue
		}
		switch {
		case !candidate.complete || candidate.connections[0] == nil || candidate.connections[1] == nil:
			formation.waiting = NativePairWaitingPeer
		case candidate.connections[0].session != nil || candidate.connections[1].session != nil:
			// A stopped session keeps its attachments until the registry
			// releases both devices.
			formation.waiting = NativePairWaitingHeld
		case now.Before(formation.notBefore):
			formation.waiting = formation.backoff
		default:
			candidates = append(candidates, *candidate)
		}
	}
	return candidates
}

// formationCommittedLocked clears a cluster's record of declined and failed
// preparations once a session of it commits. The caller holds mu.
func (c *NativePairCoordinator) formationCommittedLocked(s *NativePairSession) {
	for _, formation := range c.formations {
		if formation.session == s {
			formation.failures, formation.declines, formation.notBefore = 0, 0, time.Time{}
		}
	}
}

// nativePairBackoff doubles floor once per consecutive occurrence after the
// first, up to limit.
func nativePairBackoff(occurrences int, floor, limit time.Duration) time.Duration {
	delay := floor
	for i := 1; i < occurrences && delay < limit; i++ {
		delay *= 2
	}
	return min(delay, limit)
}

func (c *NativePairCoordinator) formPair(candidate nativePairFormationCandidate, now time.Time) {
	approval, model, ok := c.formationApproval(candidate, now)
	if !ok {
		c.recordFormation(candidate.key, nil, "", "", NativePairWaitingApproval)
		return
	}
	members := [2]*Provider{candidate.connections[0].provider, candidate.connections[1].provider}
	if waiting := c.registry.verifiedPairAdmission(members, model); waiting != NativePairWaitingNone {
		c.recordFormation(candidate.key, nil, approval, model, waiting)
		return
	}
	session, err := c.Reserve(candidate.connections, approval, verifiedPairLifetimeLimit)
	if err != nil {
		// The precheck and Reserve are separate critical sections; a member can
		// lose eligibility in between. That is a wait, not a failed session.
		c.recordFormation(candidate.key, nil, approval, model, NativePairWaitingIneligible)
		return
	}
	c.recordFormation(candidate.key, session, approval, model, NativePairWaitingNone)
}

// formationApproval selects the one catalog entry both members registered: its
// policy commitment equals theirs, both hold its model in their cluster
// inventory, both chips are allowed, and a full lifetime fits before it expires.
func (c *NativePairCoordinator) formationApproval(candidate nativePairFormationCandidate, now time.Time) (id, model string, ok bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for approvalID, entry := range c.catalog.entries {
		if hex.EncodeToString(entry.binding[:]) != candidate.key.policy || c.revoked[approvalID] ||
			!now.Add(verifiedPairLifetimeLimit).Before(entry.policy.NotAfter) {
			continue
		}
		if !candidate.models[0][entry.policy.Model] || !candidate.models[1][entry.policy.Model] {
			continue
		}
		return approvalID, entry.policy.Model, true
	}
	return "", "", false
}

func (c *NativePairCoordinator) recordFormation(key nativePairFormationKey, session *NativePairSession, approval, model string, waiting NativePairWaiting) {
	c.mu.Lock()
	defer c.mu.Unlock()
	formation := c.formations[key]
	if formation == nil {
		if session == nil {
			return
		}
		formation = &nativePairFormation{}
		c.formations[key] = formation
	}
	formation.approval, formation.model, formation.waiting = approval, model, waiting
	if session != nil {
		formation.session, formation.reformingSince = session, time.Time{}
	}
}

// verifiedPairAdmission is a read-only preview of ReserveVerifiedPair for the
// selector, so a pair that cannot form yet costs no registry write lock. It
// reports why these members would be refused now; Reserve remains the decision.
func (r *Registry) verifiedPairAdmission(members [2]*Provider, model string) NativePairWaiting {
	r.mu.RLock()
	defer r.mu.RUnlock()
	unlock := lockVerifiedPairMembers(members)
	defer unlock()
	now := time.Now()
	for _, p := range members {
		if r.providerPairHeldLocked(p, now, nil) {
			return NativePairWaitingHeld
		}
	}
	for _, p := range members {
		if _, err := r.verifiedPairMemberLocked(p, model, now, nil); err != nil || !r.verifiedPairIdleLocked(p, false) {
			return NativePairWaitingIneligible
		}
	}
	return NativePairWaitingNone
}
