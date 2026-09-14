package attestrecord

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func ValidCodeCoverage(r contracts.CodeAttestation) bool {
	return r.SEPubKey != "" && r.Version != "" && r.APNsToken != "" && r.NodePublicKey != "" && r.BinaryHash != "" && !r.AttestedAt.IsZero() && r.ContinuousCoverageUntil != nil && !r.ContinuousCoverageUntil.Before(r.AttestedAt)
}

func SameCodeProof(a, b contracts.CodeAttestation) bool {
	return a.SEPubKey == b.SEPubKey && a.Version == b.Version && a.APNsToken == b.APNsToken && a.NodePublicKey == b.NodePublicKey && a.BinaryHash == b.BinaryHash && a.AttestedAt.Equal(b.AttestedAt)
}
