// Package transcript binds each signed proof to the current connection or one
// exact durable enrollment. Recovered enrollment never supplies an assertion.
package transcript

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Binding is the immutable server-side input to one proof verification.
type Binding struct {
	Session, Challenge, PublicKey string
	Owner, Account                string
	KeyID                         *string
	AppID, Environment            string
	ProtocolVersion               int
}

func AccountScope(account string) string {
	hash := sha256.Sum256([]byte("darkbloom.app-attest.account.v1\x00" + account))
	return hex.EncodeToString(hash[:])
}

// Prepare reads recovery context once, so archive and verifier use identical
// inputs even if a failed query would succeed on an immediate second read.
func Prepare(ctx context.Context, st store.AppAttestEnrollmentStore, b Binding, action string, reply protocol.AppAttestShadowPayload) ([32]byte, *store.AppAttestEnrollment, error) {
	id := reply.KeyID
	if b.KeyID != nil {
		id = *b.KeyID
	}
	if reply.Status == nil || reply.ProtocolVersion != b.ProtocolVersion {
		return [32]byte{}, nil, errors.New("missing_signed_status")
	}
	session, challenge, publicKey := b.Session, b.Challenge, b.PublicKey
	var enrollment *store.AppAttestEnrollment
	if action == "attest" && reply.EnrollmentSession != "" && reply.EnrollmentSession != b.Session {
		if st == nil {
			return [32]byte{}, nil, errors.New("enrollment_storage")
		}
		e, err := st.GetAppAttestEnrollment(ctx, reply.EnrollmentSession)
		if err != nil {
			return [32]byte{}, nil, errors.New("enrollment_storage_error")
		}
		now := time.Now()
		if e == nil || e.Owner != b.Owner || e.KeyID != id || e.AppID != b.AppID || e.Environment != b.Environment || e.AccountScope != AccountScope(b.Account) || e.CreatedAt.After(now) {
			return [32]byte{}, nil, errors.New("enrollment_context")
		}
		if now.Sub(e.CreatedAt) > 24*time.Hour {
			return [32]byte{}, nil, errors.New("enrollment_expired")
		}
		if e.ProtocolVersion != 3 {
			return [32]byte{}, nil, errors.New("enrollment_protocol")
		}
		session, challenge, publicKey = e.ID, e.Challenge, e.PublicKey
		enrollment = e
	}
	return protocol.AppAttestShadowHashV3(action, session, b.Environment, id, challenge, publicKey, AccountScope(b.Account), reply.Status), enrollment, nil
}
