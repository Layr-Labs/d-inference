package shared

import "github.com/eigeninference/d-inference/coordinator/store"

func ValidCodeCoverage(r store.CodeAttestation) bool {
	return r.SEPubKey != "" && r.Version != "" && r.APNsToken != "" && r.NodePublicKey != "" && r.BinaryHash != "" && !r.AttestedAt.IsZero() && r.ContinuousCoverageUntil != nil && !r.ContinuousCoverageUntil.Before(r.AttestedAt)
}
