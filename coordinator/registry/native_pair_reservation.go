package registry

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Reserve is a coordinator selector API, deliberately absent from the member
// wire protocol. It creates a pending preparation hold; the only owner-start
// publication is in Handle after both signed receipts and Registry.Commit.
func (c *NativePairCoordinator) Reserve(m [2]*NativePairConnection, approvalID string, lifetime time.Duration) (*NativePairSession, error) {
	if c == nil {
		return nil, ErrNativePairApproval
	}
	// Entropy acquisition must not hold the coordinator mutex or delay another
	// session's cancellation. These IDs confer no authority before Commit.
	var ownerIDs [2][3][16]byte
	seenIDs := make(map[[16]byte]bool, 6)
	for rank := range ownerIDs {
		for field := range ownerIDs[rank] {
			id := &ownerIDs[rank][field]
			if _, e := rand.Read(id[:]); e != nil {
				return nil, ErrNativePairControl
			}
			id[6] = (id[6] & 15) | 64
			id[8] = (id[8] & 63) | 128
			if seenIDs[*id] {
				return nil, ErrNativePairControl
			}
			seenIDs[*id] = true
		}
	}
	c.mu.Lock()
	if c.closed || len(c.sessions) >= nativePairMaximumSessions || !c.validConnectionLocked(m[0]) || !c.validConnectionLocked(m[1]) || m[0] == m[1] || m[0].session != nil || m[1].session != nil {
		c.mu.Unlock()
		return nil, ErrNativePairControl
	}
	a, ok := c.catalog.entries[approvalID]
	if !ok || c.revoked[approvalID] || lifetime <= 0 || lifetime > verifiedPairLifetimeLimit || !time.Now().Add(lifetime).Before(a.policy.NotAfter) {
		c.mu.Unlock()
		return nil, ErrNativePairApproval
	}
	members := [2]*Provider{m[0].provider, m[1].provider}
	c.mu.Unlock()
	for _, p := range members {
		p.mu.Lock()
		chip := p.Hardware.ChipName
		p.mu.Unlock()
		i := sort.SearchStrings(a.policy.AllowedChips, chip)
		if i == len(a.policy.AllowedChips) || a.policy.AllowedChips[i] != chip {
			return nil, ErrNativePairApproval
		}
	}
	// The real Registry performs its own atomic bilateral hold. Release our
	// mutex across its entropy/provider-lock work, then revalidate the exact
	// attachment and approval. Any concurrent revocation frees only this still-
	// pending result; no owner can start from it.
	h, membership, e := c.registry.ReserveVerifiedPair(members, VerifiedPairRequest{Model: a.policy.Model, PlanSHA256: a.policy.PlanSHA256, ProposedRuntimeBindingSHA256: a.binding, Lifetime: lifetime})
	c.mu.Lock()
	if e != nil {
		c.mu.Unlock()
		return nil, e
	}
	if c.closed || c.revoked[approvalID] || len(c.sessions) >= nativePairMaximumSessions || !c.validConnectionLocked(m[0]) || !c.validConnectionLocked(m[1]) || m[0].session != nil || m[1].session != nil || !time.Now().Before(membership.PrepareBefore) || !membership.ExpiresAt.Before(a.policy.NotAfter) {
		_ = c.registry.CancelVerifiedPair(h)
		c.mu.Unlock()
		return nil, ErrNativePairApproval
	}
	ctx, stop := context.WithCancel(context.Background())
	s := &NativePairSession{coordinator: c, handle: h, membership: membership, approval: a, connections: m, ctx: ctx, stop: stop, writersStopped: make(chan struct{})}
	common := protocol.NativeAuthorizationCommon{Epoch: membership.Epoch, MembershipGeneration: membership.Generation, NativePolicyGeneration: a.policy.Generation, MembershipTranscriptSHA256: membership.TranscriptSHA256, ApprovedNativeBindingSHA256: a.binding, PlanSHA256: a.policy.PlanSHA256, ArtifactSHA256: a.policy.ArtifactSHA256, NativeRuntimeSHA256: a.policy.NativeRuntimeSHA256, CapabilitySHA256: a.policy.CapabilitySHA256, ResourcePolicySHA256: a.policy.ResourcePolicySHA256, ProfileSHA256: a.policy.ProfileSHA256, Schedule: a.policy.Schedule, MaximumTransportFrame: a.policy.MaximumTransportFrame, MaximumPlaintext: a.policy.MaximumPlaintext, MaximumRecords: a.policy.MaximumRecords, MaximumCumulativePlaintext: a.policy.MaximumCumulativePlaintext}
	for rank := range m {
		start := protocol.NativeAuthorizationStart{Common: common, Rank: uint8(rank), OwnerIncarnation: ownerIDs[rank][0], LeaseID: ownerIDs[rank][1], LaunchID: ownerIDs[rank][2]}
		if _, e = start.Canonical(); e != nil {
			stop()
			_ = c.registry.CancelVerifiedPair(h)
			c.mu.Unlock()
			return nil, e
		}
		s.starts[rank] = start
		s.queues[rank] = make(chan []byte, nativePairQueueFrames)
	}
	for rank := range m {
		start, _ := s.starts[rank].Canonical()
		payload := []byte("DBNPR\x01")
		payload = binary.BigEndian.AppendUint32(payload, uint32(len(a.canonical)))
		payload = append(payload, a.canonical...)
		payload = append(payload, start...)
		if e = c.enqueueLocked(s, rank, protocol.TypeNativePairPrepare, payload); e != nil {
			stop()
			_ = c.registry.CancelVerifiedPair(h)
			c.mu.Unlock()
			return nil, e
		}
	}
	c.sessions[membership.Epoch] = s
	for _, n := range m {
		n.session = s
	}
	// Publish worker ownership before dropping mu; Cancel may run immediately.
	s.workers.Add(2)
	c.mu.Unlock()
	for rank := range m {
		go c.writeLoop(s, rank)
	}
	go func() { <-h.Done(); c.Cancel(s); c.finishWriters(s) }()
	return s, nil
}
