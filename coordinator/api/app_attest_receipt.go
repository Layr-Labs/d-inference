package api

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

type receiptVerificationContext struct {
	AppID       string   `json:"app_id"`
	Environment string   `json:"environment"`
	PublicKey   []byte   `json:"public_key"`
	ClientHash  [32]byte `json:"client_hash"`
}

func (x *appAttestShadowSession) initialReceipt(proof []byte, hash [32]byte) *store.AppAttestReceipt {
	raw := appattest.ExtractReceipt(proof)
	contextJSON, _ := json.Marshal(receiptVerificationContext{AppID: x.key.AppID, Environment: x.key.Environment, PublicKey: x.key.PublicKey, ClientHash: hash})
	r := &store.AppAttestReceipt{ID: uuid.NewString(), KeyID: x.key.KeyID, EvidenceID: x.evidenceID, ReceivedAt: time.Now().UTC(), Body: raw, Context: contextJSON}
	verifyReceiptRecord(r, receiptVerificationContext{x.key.AppID, x.key.Environment, x.key.PublicKey, hash})
	return r
}

func verifyReceiptRecord(r *store.AppAttestReceipt, c receiptVerificationContext) {
	verified, err := appattest.VerifyReceipt(r.Body, c.PublicKey, c.AppID, c.ClientHash, r.ReceivedAt)
	r.NextAt = r.ReceivedAt.Add(time.Hour)
	if err != nil {
		r.Outcome = err.Error()
		r.Details = json.RawMessage(`{}`)
		return
	}
	r.Outcome = "verified"
	r.Details, _ = json.Marshal(verified)
	r.ExpiresAt = verified.ExpiresAt
	r.NextAt = verified.NotBefore.Add(time.Minute)
	if r.NextAt.Before(r.ReceivedAt) {
		r.NextAt = r.ReceivedAt.Add(time.Minute)
	}
}
