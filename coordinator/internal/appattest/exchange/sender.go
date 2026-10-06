package exchange

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type SendDependencies struct {
	Enrollments store.AppAttestEnrollmentStore
	Scope       *storagebudget.Scope
	Integrity   *evidence.Integrity
	Transport   func(context.Context, []byte) error
}

type SentChallenge struct {
	Challenge, Expected, Outcome string
	Started                      time.Time
	Sent                         bool
}

// Send records enrollment before transport and issues assertion completeness
// at challenge creation, not when a queued reply is later dequeued.
func Send(ctx context.Context, deps SendDependencies, b transcript.Binding, key *store.AppAttestShadowKey, action string) SentChallenge {
	var nonce [32]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return SentChallenge{Outcome: "internal_error"}
	}
	r := SentChallenge{Challenge: base64.StdEncoding.EncodeToString(nonce[:]), Expected: map[string]string{"prepare": "ready", "attest": "attestation", "assert": "assertion"}[action]}
	p := protocol.AppAttestShadowPayload{Action: action, Session: b.Session, Environment: b.Environment, ProtocolVersion: b.ProtocolVersion, AccountScope: transcript.AccountScope(b.Account)}
	if key != nil {
		p.KeyID = key.KeyID
	}
	if action == "attest" {
		p.Challenge = r.Challenge
		if deps.Enrollments == nil {
			r.Outcome = "storage_unavailable"
			return r
		}
		release, ok := deps.Scope.Acquire()
		if !ok {
			r.Outcome = "storage_busy"
			return r
		}
		operation, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := deps.Enrollments.SaveAppAttestEnrollment(operation, store.AppAttestEnrollment{ProtocolVersion: b.ProtocolVersion, ID: b.Session, Owner: b.Owner, KeyID: key.KeyID, CreatedAt: time.Now().UTC(), Environment: b.Environment,
			AppID: b.AppID, Challenge: r.Challenge, PublicKey: b.PublicKey, AccountScope: transcript.AccountScope(b.Account)})
		cancel()
		release()
		if err != nil {
			r.Outcome = "storage_error"
			return r
		}
	}
	if action == "assert" {
		deps.Integrity.BeginChallenge()
		pub, err := base64.StdEncoding.DecodeString(b.PublicKey)
		if err != nil || len(pub) != 32 {
			r.Outcome = "encryption_key"
			return r
		}
		keys, err := e2e.GenerateSessionKeys()
		if err != nil {
			r.Outcome = "internal_error"
			return r
		}
		var recipient [32]byte
		copy(recipient[:], pub)
		payload, err := e2e.Encrypt([]byte(r.Challenge), recipient, keys)
		if err != nil {
			r.Outcome = "internal_error"
			return r
		}
		p.EncryptedChallenge = &protocol.EncryptedPayload{EphemeralPublicKey: payload.EphemeralPublicKey, Ciphertext: payload.Ciphertext}
	}
	data, _ := json.Marshal(protocol.AppAttestShadowMessage{Type: protocol.TypeAppAttestShadow, Payload: p})
	r.Started = time.Now()
	if err := deps.Transport(ctx, data); err != nil {
		r.Outcome = "send_failed"
		return r
	}
	r.Outcome, r.Sent = "attempted", true
	return r
}
