package receipt

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

type VerificationContext struct {
	AppID       string   `json:"app_id"`
	Environment string   `json:"environment"`
	PublicKey   []byte   `json:"public_key"`
	ClientHash  [32]byte `json:"client_hash"`
}

func EnrollmentRecord(key *store.AppAttestShadowKey, evidenceID string, proof []byte, hash [32]byte, now time.Time) *store.AppAttestReceipt {
	raw := appattest.ExtractReceipt(proof)
	contextJSON, _ := json.Marshal(VerificationContext{AppID: key.AppID, Environment: key.Environment, PublicKey: key.PublicKey, ClientHash: hash})
	r := &store.AppAttestReceipt{ID: uuid.NewString(), KeyID: key.KeyID, EvidenceID: evidenceID, ReceivedAt: now.UTC(), Body: raw, Context: contextJSON}
	verifyInitialReceiptRecord(r, VerificationContext{key.AppID, key.Environment, key.PublicKey, hash})
	return r
}

func verifyReceiptRecord(r *store.AppAttestReceipt, c VerificationContext) {
	verifyReceiptRecordMode(r, c, false)
}

func verifyInitialReceiptRecord(r *store.AppAttestReceipt, c VerificationContext) {
	verifyReceiptRecordMode(r, c, true)
}

func verifyReceiptRecordMode(r *store.AppAttestReceipt, c VerificationContext, recoverEnrollment bool) {
	verified, err := appattest.VerifyReceipt(r.Body, c.PublicKey, c.AppID, c.ClientHash, r.ReceivedAt)
	r.NextAt = r.ReceivedAt.Add(time.Hour)
	r.Outcome = "verified"
	if recoverEnrollment && err != nil && err.Error() == "receipt_creation_time" {
		// Recovery may deliver an original enrollment after its freshness window.
		// Only a fully validated, unexpired historical receipt can seed renewal;
		// it must never become a fresh receipt merely by retrying the submission.
		verified, err = appattest.ReceiptForRenewal(r.Body, c.PublicKey, c.AppID, c.ClientHash, r.ReceivedAt)
		r.Outcome = "renewal_required"
	}
	if err != nil {
		r.Outcome = err.Error()
		r.Details = json.RawMessage(`{}`)
		return
	}
	if !recoverEnrollment && verified.Type != "RECEIPT" {
		r.Outcome = "receipt_refresh_type"
		r.Details = json.RawMessage(`{}`)
		return
	}
	if recoverEnrollment && verified.Type != "ATTEST" {
		r.Outcome = "receipt_enrollment_type"
		r.Details = json.RawMessage(`{}`)
		return
	}
	r.Details, _ = json.Marshal(verified)
	r.ExpiresAt = verified.ExpiresAt
	r.NextAt = verified.NotBefore.Add(time.Minute)
	if r.NextAt.Before(r.ReceivedAt) {
		r.NextAt = r.ReceivedAt.Add(time.Minute)
	}
}
