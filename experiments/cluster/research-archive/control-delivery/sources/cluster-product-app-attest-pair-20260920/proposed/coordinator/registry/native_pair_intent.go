package registry

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/base64"
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const nativePairIntentWait = 90 * time.Second

// All fields belong to the exact original connection and are guarded by c.mu.
// No capability/reservation/provider model state is created by this record.
type nativePairConfiguration struct {
	value    protocol.NativePairIntent
	message  protocol.NativePairIntentMessage
	before   time.Time
	consumed bool
	stop     chan struct{}
}
type nativePairIntentSelection struct{ records [2]*nativePairConfiguration }

// Configure consumes one signed consent per TLS member connection. Signature
// authority and current trust are checked at selection, after initial trust
// proof may have completed. Unverified stored bytes never authorize a reserve.
func (c *NativePairCoordinator) Configure(n *NativePairConnection, m *protocol.NativePairIntentMessage) error {
	if c == nil || m == nil || m.Validate() != nil || m.Signature == "" {
		return ErrNativePairControl
	}
	raw, _ := base64.StdEncoding.DecodeString(m.Payload)
	value, e := protocol.DecodeNativePairIntent(raw)
	if e != nil {
		return e
	}
	c.mu.Lock()
	if c.closed || !c.validConnectionLocked(n) || n.configuration != nil || n.session != nil || m.MemberNonce != n.nonce || n.inboundSequence == math.MaxUint64 || m.Sequence != n.inboundSequence+1 {
		c.mu.Unlock()
		return ErrNativePairControl
	}
	// A configured identity cannot add policy bytes or recover a revoked entry.
	a, ok := c.catalog.entries[value.ApprovalID]
	if !ok || c.revoked[value.ApprovalID] || a.binding != value.PolicySHA256 || !time.Now().Add(time.Duration(value.LifetimeSeconds)*time.Second).Before(a.policy.NotAfter) {
		c.mu.Unlock()
		return ErrNativePairApproval
	}
	configured := 0
	for _, current := range c.connections {
		if current.configuration != nil {
			configured++
		}
	}
	if configured >= 2*nativePairMaximumSessions {
		c.mu.Unlock()
		return ErrNativePairControl
	}
	before := time.Now().Add(nativePairIntentWait)
	if value.Rank == 1 {
		before = a.policy.NotAfter.Add(-time.Duration(value.LifetimeSeconds) * time.Second)
	}
	record := &nativePairConfiguration{value: value, message: *m, before: before, stop: make(chan struct{})}
	n.inboundSequence = m.Sequence
	n.configuration = record
	if value.Rank == 0 {
		c.intentWorkers.Add(1)
	}
	c.mu.Unlock()
	if value.Rank == 0 {
		go c.selectConfiguredPair(n, record)
	}
	return nil
}
func (c *NativePairCoordinator) selectConfiguredPair(leader *NativePairConnection, record *nativePairConfiguration) {
	defer c.intentWorkers.Done()
	timer := time.NewTimer(time.Until(record.before))
	defer timer.Stop()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		members, selection, ok := c.configuredSelection(leader, record)
		if ok {
			if _, e := c.reserve(members, record.value.ApprovalID, time.Duration(record.value.LifetimeSeconds)*time.Second, selection); e == nil {
				return
			}
		}
		select {
		case <-record.stop:
			return
		case <-timer.C:
			return
		case <-ticker.C:
		}
	}
}
func sameConfiguredPair(a, b protocol.NativePairIntent) bool {
	return a.Rank == 0 && b.Rank == 1 && a.ClusterID == b.ClusterID && a.ApprovalID == b.ApprovalID && a.PolicySHA256 == b.PolicySHA256 && a.MemberIDs == b.MemberIDs && a.SignerSHA256 == b.SignerSHA256 && a.LifetimeSeconds == b.LifetimeSeconds
}
func (c *NativePairCoordinator) configuredSelection(leader *NativePairConnection, record *nativePairConfiguration) ([2]*NativePairConnection, *nativePairIntentSelection, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var members [2]*NativePairConnection
	if c.closed || !c.validConnectionLocked(leader) || leader.configuration != record || record.consumed || !time.Now().Before(record.before) {
		return members, nil, false
	}
	members[0] = leader
	for _, candidate := range c.connections {
		x := candidate.configuration
		if candidate == leader || !c.validConnectionLocked(candidate) || candidate.session != nil || x == nil || x.consumed || !time.Now().Before(x.before) || !sameConfiguredPair(record.value, x.value) {
			continue
		}
		if members[1] != nil {
			return [2]*NativePairConnection{}, nil, false
		} // Ambiguous duplicates refuse, never first-match wins.
		members[1] = candidate
	}
	if members[1] == nil {
		return members, nil, false
	}
	selection := &nativePairIntentSelection{records: [2]*nativePairConfiguration{record, members[1].configuration}}
	return members, selection, c.configuredIntentValidLocked(members, selection, nil)
}

// Called under c.mu before AND after the Registry's atomic bilateral hold.
// Lock order stays c.mu -> Registry.mu -> deterministic provider locks.
func (c *NativePairCoordinator) configuredIntentValidLocked(m [2]*NativePairConnection, s *nativePairIntentSelection, held *VerifiedPairHandle) bool {
	if s == nil {
		return true
	} // Existing trusted in-process selector API is unchanged.
	if m[0] == nil || m[1] == nil || m[0] == m[1] {
		return false
	}
	for i, n := range m {
		if !c.validConnectionLocked(n) || n.configuration != s.records[i] || n.configuration.consumed || !time.Now().Before(n.configuration.before) {
			return false
		}
	}
	a, ok := c.catalog.entries[s.records[0].value.ApprovalID]
	if !ok || c.revoked[a.policy.ID] || a.binding != s.records[0].value.PolicySHA256 {
		return false
	}
	if !sameConfiguredPair(s.records[0].value, s.records[1].value) {
		return false
	}
	c.registry.mu.RLock()
	defer c.registry.mu.RUnlock()
	providers := [2]*Provider{m[0].provider, m[1].provider}
	unlock := lockVerifiedPairMembers(providers)
	defer unlock()
	for rank, p := range providers {
		// At the post-reservation check the exact pending hold is allowed, never a
		// different device/session hold. The registry still owns its full rechecks.
		var except *verifiedPairState
		if held != nil {
			if held.registry != c.registry || held.state == nil || c.registry.verifiedPairs.connections[p] != held.state {
				return false
			}
			except = held.state
		}
		member, e := c.registry.verifiedPairMemberLocked(p, a.policy.Model, time.Now(), except)
		if e != nil {
			return false
		}
		raw, e := base64.StdEncoding.DecodeString(member.controlPublicKey())
		if e != nil || sha256.Sum256(raw) != s.records[rank].value.SignerSHA256[rank] {
			return false
		}
		key, e := attestation.ParseP256PublicKey(raw)
		if e != nil {
			return false
		}
		signed, e := s.records[rank].message.SigningBytes()
		if e != nil {
			return false
		}
		digest := sha256.Sum256(signed)
		signature, e := base64.StdEncoding.DecodeString(s.records[rank].message.Signature)
		if e != nil || !ecdsa.VerifyASN1(key, digest[:], signature) {
			return false
		}
	}
	return true
}
func stopConfiguredIntent(n *NativePairConnection) {
	if n.configuration != nil {
		select {
		case <-n.configuration.stop:
		default:
			close(n.configuration.stop)
		}
	}
}
