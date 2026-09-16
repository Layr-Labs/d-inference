package routerecord

import (
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func ValidateRequestOutcome(r contracts.RequestOutcomeRecord) error {
	if r.CoordRequestID == "" || len(r.CoordRequestID) > 64 || r.SchemaVersion != contracts.RequestOutcomeSchemaVersion || r.Revision < 1 || r.ReceivedAt.IsZero() || r.UpdatedAt.IsZero() {
		return errors.New("store: invalid request outcome identity/version")
	}
	switch r.ResponseTerminal {
	case "", "unknown", "completed", "incomplete", "error":
	default:
		return errors.New("store: invalid response terminal")
	}
	if len(r.Termination) > 64 || len(r.ResponseProgress) > 64 || len(r.ProviderOutcome) > 64 {
		return errors.New("store: oversized request outcome classification")
	}
	if len(r.Attempts) > contracts.MaxRequestOutcomeAttempts || len(r.Model) > 256 || len(r.Endpoint) > 64 || len(r.RawReason) > 96 || len(r.RawStage) > 64 || len(r.NormalizedCode) > 128 {
		return errors.New("store: oversized request outcome")
	}
	for _, a := range r.Attempts {
		if a.RequestID == "" || len(a.RequestID) > 64 || len(a.BackupOf) > 64 || len(a.RawReason) > 96 || len(a.TerminalCause) > 96 || len(a.ProviderOutcome) > 64 || len(a.FinalStatus) > 64 || len(a.NormalizedCode) > 128 {
			return errors.New("store: invalid request attempt outcome")
		}
	}
	return nil
}
