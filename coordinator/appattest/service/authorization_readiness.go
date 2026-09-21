package service

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

func applyAppAttestReadiness(e *appattest.AuthorizationEvidence, state store.AppAttestReadiness) {
	e.RevocationKnown, e.Revoked = true, state.Revoked
	e.ReceiptVerified, e.RiskMetric = false, nil
	e.ReceiptExpiresAt, e.ReceiptRenewAt = time.Time{}, time.Time{}
	if r := state.Receipt; r != nil {
		var receipt appattest.Receipt
		if json.Unmarshal(r.Details, &receipt) == nil {
			e.ReceiptVerified, e.RiskMetric = r.Outcome == "verified", receipt.RiskMetric
			e.ReceiptExpiresAt, e.ReceiptRenewAt = r.ExpiresAt, r.NextAt
		}
	}
}
