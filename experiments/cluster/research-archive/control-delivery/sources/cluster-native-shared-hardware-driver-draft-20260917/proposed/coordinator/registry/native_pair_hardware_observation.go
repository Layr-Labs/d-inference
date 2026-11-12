//go:build native_pair_hardware_experiment

package registry

import (
	"crypto/sha256"
	"encoding/hex"
	"time"
)

// Diagnostic selection only. Reserve still performs the authoritative atomic
// hold and repeats every trust/current-connection/admission check. No state is
// prepared, granted, refreshed, or released by this observation.
type NativeHardwareDevice struct {
	Serial            string `json:"serial"`
	SEPublicKeySHA256 string `json:"sePublicKeySHA256"`
}

func (c *NativePairCoordinator) HardwareSelectedMembers(devices [2]NativeHardwareDevice, approvalID string) ([2]*Provider, bool) {
	var selected [2]*Provider
	if c == nil || devices[0].Serial == "" || devices[1].Serial == "" || devices[0].Serial == devices[1].Serial ||
		!verifiedPairSHA(devices[0].SEPublicKeySHA256) || !verifiedPairSHA(devices[1].SEPublicKeySHA256) || devices[0].SEPublicKeySHA256 == devices[1].SEPublicKeySHA256 {
		return selected, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	a, ok := c.catalog.entries[approvalID]
	if !ok || c.closed || c.revoked[approvalID] {
		return selected, false
	}
	c.registry.mu.RLock()
	defer c.registry.mu.RUnlock()
	// Private isolated coordinator only. No scan/selection over a public fleet.
	if len(c.registry.providers) > 16 {
		return selected, false
	}
	for _, p := range c.registry.providers {
		p.mu.Lock()
		for rank, want := range devices {
			att := p.AttestationResult
			if att == nil || att.SerialNumber != want.Serial {
				continue
			}
			h := sha256.Sum256([]byte(att.PublicKey))
			if hex.EncodeToString(h[:]) != want.SEPublicKeySHA256 {
				continue
			}
			// Refuse duplicate connections even when one is not yet attested.
			if selected[rank] != nil {
				p.mu.Unlock()
				return [2]*Provider{}, false
			}
			selected[rank] = p
		}
		p.mu.Unlock()
	}
	if selected[0] == nil || selected[1] == nil || selected[0] == selected[1] {
		return selected, false
	}
	unlock := lockVerifiedPairMembers(selected)
	defer unlock()
	now := time.Now()
	for rank, p := range selected {
		n := c.connections[p]
		if !c.validConnectionLocked(n) || n.session != nil {
			return selected, false
		}
		member, err := c.registry.verifiedPairMemberLocked(p, a.policy.Model, now, nil)
		h := sha256.Sum256([]byte(member.SEPublicKey))
		if err != nil || member.DeviceSerial != devices[rank].Serial || hex.EncodeToString(h[:]) != devices[rank].SEPublicKeySHA256 || !c.registry.verifiedPairIdleLocked(p, false) {
			return selected, false
		}
	}
	return selected, true
}

// Public scalars copied under the existing coordinator -> Registry lock order.
// Published means actual enqueue/close attempts ended; it is NOT peer receipt.
// The leader's actual owner.shutdown return supplies the separate remote-view
// aggregate receipt join. No secrets or inference payloads are read here.
type NativeHardwareObservation struct {
	Epoch                      string                  `json:"epoch"`
	Generation                 uint64                  `json:"generation"`
	ApprovalID                 string                  `json:"approvalID"`
	MembershipSHA256           string                  `json:"membershipSHA256"`
	ApprovedBindingSHA256      string                  `json:"approvedBindingSHA256"`
	PlanSHA256                 string                  `json:"planSHA256"`
	NativeSHA256               string                  `json:"nativeSHA256"`
	ProviderIDs                [2]string               `json:"providerIDs"`
	Devices                    [2]NativeHardwareDevice `json:"devices"`
	ProviderBinarySHA256       [2]string               `json:"providerBinarySHA256"`
	StartSHA256                [2]string               `json:"startSHA256"`
	ExpiresAt                  time.Time               `json:"expiresAt"`
	Phase                      VerifiedPairPhase       `json:"phase"`
	Released                   [2]bool                 `json:"released"`
	Committed                  bool                    `json:"committed"`
	KeyConfirmed               [2]bool                 `json:"keyConfirmed"`
	MeshRound                  uint8                   `json:"meshRound"`
	WorkerReady                [2]bool                 `json:"workerReady"`
	WorkerRecords              [2]uint64               `json:"workerRecords"`
	WorkerBytes                [2]uint64               `json:"workerBytes"`
	RelayWritersEnded          bool                    `json:"relayWritersEnded"`
	CancellationPublished      bool                    `json:"cancellationPublished"`
	AggregatePublicationEnded  bool                    `json:"aggregatePublicationEnded"`
	AggregatePublicationFailed [2]bool                 `json:"aggregatePublicationFailed"`
	ConnectionClosed           [2]bool                 `json:"connectionClosed"`
}

func (s *NativePairSession) HardwareObservation() NativeHardwareObservation {
	c := s.coordinator
	c.mu.Lock()
	defer c.mu.Unlock()
	c.registry.mu.RLock()
	defer c.registry.mu.RUnlock()
	m := s.membership
	v := NativeHardwareObservation{Epoch: hex.EncodeToString(m.Epoch[:]), Generation: m.Generation,
		ApprovalID: s.approval.policy.ID, MembershipSHA256: hex.EncodeToString(m.TranscriptSHA256[:]),
		ApprovedBindingSHA256: hex.EncodeToString(m.ProposedRuntimeBindingSHA256[:]),
		PlanSHA256:            hex.EncodeToString(m.PlanSHA256[:]), NativeSHA256: hex.EncodeToString(s.approval.policy.NativeRuntimeSHA256[:]),
		ExpiresAt: m.ExpiresAt, Committed: s.committed, KeyConfirmed: s.keyConfirmed, MeshRound: s.meshRound,
		WorkerReady: s.workerReady, WorkerRecords: s.workerRecords, WorkerBytes: s.workerBytes,
		RelayWritersEnded: s.writersEnded, CancellationPublished: s.cancellationPublished,
		AggregatePublicationEnded: s.workerReleasePublished, AggregatePublicationFailed: s.workerReleaseFailed}
	// The retained actual handle remains inspectable after its indexes retire.
	if s.handle != nil && s.handle.registry == c.registry && s.handle.state != nil {
		v.Phase = s.handle.state.phase
		v.Released = s.handle.state.released
	}
	for rank := range s.starts {
		v.ProviderIDs[rank] = m.Members[rank].ProviderID
		keyHash := sha256.Sum256([]byte(m.Members[rank].SEPublicKey))
		v.Devices[rank] = NativeHardwareDevice{m.Members[rank].DeviceSerial, hex.EncodeToString(keyHash[:])}
		v.ProviderBinarySHA256[rank] = m.Members[rank].ProviderBinaryHash
		b, _ := s.starts[rank].Canonical()
		h := sha256.Sum256(b)
		v.StartSHA256[rank] = hex.EncodeToString(h[:])
		v.ConnectionClosed[rank] = s.connections[rank].closed
	}
	return v
}

func (v NativeHardwareObservation) ReleasedNormally() bool {
	return v.Committed && v.KeyConfirmed == [2]bool{true, true} && v.MeshRound == 4 &&
		v.WorkerReady == [2]bool{true, true} && v.Phase == VerifiedPairReleased &&
		v.Released == [2]bool{true, true} && v.RelayWritersEnded && v.CancellationPublished &&
		v.AggregatePublicationEnded && v.AggregatePublicationFailed == [2]bool{false, false}
}
