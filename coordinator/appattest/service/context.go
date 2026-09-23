package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) accountScope() string {
	hash := sha256.Sum256([]byte("darkbloom.app-attest.account.v1\x00" + x.account))
	return hex.EncodeToString(hash[:])
}

type shadowProofContext struct {
	Hash [32]byte
	Err  error
}

func (x *Session) clientHash(ctx context.Context, action string, reply protocol.AppAttestShadowPayload) ([32]byte, error) {
	hash, _, err := x.prepareClientHash(ctx, action, reply)
	return hash, err
}

// Snapshot recovery inputs once so the archived transcript is exactly the one
// used by verification, even if a database timeout resolves on the next query.
func (x *Session) prepareClientHash(ctx context.Context, action string, reply protocol.AppAttestShadowPayload) ([32]byte, *store.AppAttestEnrollment, error) {
	id := reply.KeyID
	if x.key != nil {
		id = x.key.KeyID
	}
	if x.protocolVersion < 2 {
		return protocol.AppAttestShadowHash(action, x.id, x.s.config.Environment, id, x.challenge, x.publicKey), nil, nil
	}
	if reply.Status == nil || reply.ProtocolVersion != x.protocolVersion {
		return [32]byte{}, nil, errors.New("missing_signed_status")
	}
	session, challenge, publicKey := x.id, x.challenge, x.publicKey
	version := x.protocolVersion
	var enrollment *store.AppAttestEnrollment
	if action == "attest" && reply.EnrollmentSession != "" && reply.EnrollmentSession != x.id {
		st, ok := store.As[store.AppAttestEnrollmentStore](x.s.store)
		if !ok {
			return [32]byte{}, nil, errors.New("enrollment_storage")
		}
		e, err := st.GetAppAttestEnrollment(ctx, reply.EnrollmentSession)
		if err != nil {
			return [32]byte{}, nil, errors.New("enrollment_storage_error")
		}
		now := time.Now()
		if e == nil || e.Owner != x.owner || e.KeyID != id || e.AppID != x.s.config.AppID || e.Environment != x.s.config.Environment || e.AccountScope != x.accountScope() || e.CreatedAt.After(now) {
			return [32]byte{}, nil, errors.New("enrollment_context")
		}
		if now.Sub(e.CreatedAt) > 24*time.Hour {
			// The client's proof-cache clock starts after Apple's response;
			// this server context starts before the call. Reject the old proof
			// but allow a later prepare to observe expiry and replace the key.
			return [32]byte{}, nil, errors.New("enrollment_expired")
		}
		// This recovers enrollment only. A fresh assertion, encrypted to the
		// new connection's actual endpoint, must still follow every reconnect.
		session, challenge, publicKey = e.ID, e.Challenge, e.PublicKey
		enrollment = e
		version = e.ProtocolVersion
		if version == 0 {
			version = 2
		}
		if version != 2 && version != 3 {
			return [32]byte{}, nil, errors.New("enrollment_protocol")
		}
	}
	if version == 3 {
		return protocol.AppAttestShadowHashV3(action, session, x.s.config.Environment, id, challenge, publicKey, x.accountScope(), reply.Status), enrollment, nil
	}
	return protocol.AppAttestShadowHashV2(action, session, x.s.config.Environment, id, challenge, publicKey, x.accountScope(), reply.Status), enrollment, nil
}

func (x *machineInventorySession) recordStatus(status *protocol.AppAttestStatus) {
	x.mu.Lock()
	x.observation.OSSource = "app_attest_assertion_report"
	x.observation.OSObservedAt = time.Now().UTC()
	x.observation.OSVersion = status.OSVersion
	x.observation.OSMajor = reportedOSMajor(status.OSVersion)
	x.observation.OSBuild = status.OSBuild
	x.mu.Unlock()
	x.capture(false)
}

func (x *Session) machineID() string {
	if x.inventory == nil {
		return ""
	}
	return x.inventory.snapshot().ID
}
func (x *Session) keyOwnerMatches(ctx context.Context, key *store.AppAttestShadowKey) bool {
	if key.Owner == x.owner {
		return true
	}
	// A claimed key ID never assigns identity. Same-account reuse must first
	// prove custody through a fresh encrypted assertion. Only after its durable
	// acceptance does inventory attach the credential alias to this session.
	if x.protocolVersion >= 2 && x.account != "" && key.AccountID == x.account {
		return true
	}
	if x.account == "" || key.AccountID != x.account || key.MachineID == "" || x.machineID() == "" {
		return false
	}
	st, ok := store.As[store.MachineIdentityLookupStore](x.s.store)
	if !ok {
		return false
	}
	canonical, err := st.CanonicalMachineID(ctx, key.MachineID)
	current, currentErr := st.CanonicalMachineID(ctx, x.machineID())
	return err == nil && currentErr == nil && canonical != "" && canonical == current
}
