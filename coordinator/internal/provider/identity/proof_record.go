package identity

import (
	"time"

	identitystate "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/state"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (r proofRecord) Recent(now time.Time, window time.Duration) bool {
	age := now.Sub(r.At)
	return age >= -trustreuse.ClockSkewTolerance && age < window
}

func (r proofRecord) Continuous(now time.Time) bool {
	if r.BinaryHash == "" || r.NodeKey == "" || r.Token == "" || r.CoveredUntil.IsZero() || r.CoveredUntil.Before(r.At) {
		return false
	}
	gap := now.Sub(r.CoveredUntil)
	return gap >= 0 && gap <= identitystate.ContinuityGap
}

func (r proofRecord) Persisted(seKey string) store.CodeAttestation {
	out := store.CodeAttestation{SEPubKey: seKey, Version: r.Version, AttestedAt: r.At,
		APNsToken: r.Token, NodePublicKey: r.NodeKey, BinaryHash: r.BinaryHash}
	if !r.CoveredUntil.IsZero() {
		until := r.CoveredUntil
		out.ContinuousCoverageUntil = &until
	}
	return out
}
