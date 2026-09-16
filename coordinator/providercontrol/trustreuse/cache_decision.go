package trustreuse

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (c *cache) decide(input Input) result {
	if input.SEPubKey == "" || input.Serial == "" || input.FreshBinaryHash == "" {
		return result{Reason: ReasonMissingIdentity}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[input.SEPubKey]
	if !ok {
		return result{Reason: ReasonNoDeviceEvidence}
	}
	if r.serial != input.Serial {
		return result{Reason: ReasonSerialMismatch}
	}
	if r.revokedAt != nil {
		return result{Reason: ReasonRevoked}
	}
	if r.trustLevel != string(registry.TrustHardware) {
		return result{Reason: ReasonNotHardware}
	}
	if !r.sipEnabled || !r.secureBootFull {
		return result{Reason: ReasonRecordedPostureBad}
	}
	continuity, freshOK := c.freshnessLocked(r)
	if !freshOK {
		return result{Reason: ReasonProofExpired}
	}
	if r.lastVerifiedBinaryHash == input.FreshBinaryHash {
		decision := DecisionSameBinary
		if continuity {
			decision = DecisionContinuity
		}
		return result{
			Decision: decision,
			Reason:   ReasonAllowed,
			Record:   r,
		}
	}
	if _, approvedFrom := input.ReleaseTransition.ApprovedFromBinaryHashes[r.lastVerifiedBinaryHash]; input.ReleaseTransition.Approved && approvedFrom &&
		input.ReleaseTransition.BinaryHash == input.FreshBinaryHash {
		decision := DecisionApprovedReleaseTransition
		if continuity {
			decision = DecisionContinuityReleaseTransition
		}
		return result{
			Decision: decision,
			Reason:   ReasonAllowed,
			Record:   r,
		}
	}
	return result{Reason: ReasonTransitionUnapproved}
}

// freshnessLocked evaluates the two admission premises against the caller's
// record. ok is true when either holds; continuity reports that the record was
// admitted by the connection-continuity premise (wall-clock window stale, but
// the coordinator-measured offline gap now-ContinuousCoverageUntil is within
// the reconnect-gap allowance). A hardware proof dated in the FUTURE beyond
// skew tolerance is corrupt/forged and never admits via either premise.
// Caller holds c.mu.
func (c *cache) freshnessLocked(r record) (continuity, ok bool) {
	now := c.now()
	age := now.Sub(r.hardwareProofVerifiedAt)
	if age < -clockSkewTolerance {
		return false, false
	}
	if age < c.reuseWindow {
		return false, true
	}
	if c.reconnectGap <= 0 || r.continuousCoverageUntil.IsZero() {
		return false, false
	}
	gap := now.Sub(r.continuousCoverageUntil)
	if gap < -clockSkewTolerance || gap > c.reconnectGap {
		return false, false
	}
	return true, true
}

func (c *cache) reuse(seKey, serial, freshBinaryHash string, facts ...ReleaseTransition) (record, bool) {
	var fact ReleaseTransition
	if len(facts) > 0 {
		fact = facts[0]
	}
	result := c.decide(Input{
		SEPubKey: seKey, Serial: serial, FreshBinaryHash: freshBinaryHash,
		ReleaseTransition: fact,
	})
	return result.Record, result.Decision != ""
}

func (c *cache) hasFreshRecord(seKey, serial string) bool {
	if seKey == "" || serial == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.records[seKey]
	if !ok || r.serial != serial || r.revokedAt != nil ||
		r.trustLevel != string(registry.TrustHardware) {
		return false
	}
	_, ok = c.freshnessLocked(r)
	return ok
}
