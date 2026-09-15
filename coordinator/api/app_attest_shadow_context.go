package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *appAttestShadowSession) accountScope() string {
	hash := sha256.Sum256([]byte("darkbloom.app-attest.account.v1\x00" + x.account))
	return hex.EncodeToString(hash[:])
}

func (x *appAttestShadowSession) clientHash(ctx context.Context, action string, reply protocol.AppAttestShadowPayload) ([32]byte, error) {
	id := reply.KeyID
	if x.key != nil {
		id = x.key.KeyID
	}
	if x.protocolVersion != 2 {
		return protocol.AppAttestShadowHash(action, x.id, x.s.appAttestShadow.Environment, id, x.challenge, x.publicKey), nil
	}
	if reply.Status == nil || reply.ProtocolVersion != 2 {
		return [32]byte{}, errors.New("missing_signed_status")
	}
	session, challenge, publicKey := x.id, x.challenge, x.publicKey
	if action == "attest" && reply.EnrollmentSession != "" && reply.EnrollmentSession != x.id {
		st, ok := store.As[store.AppAttestEnrollmentStore](x.s.store)
		if !ok {
			return [32]byte{}, errors.New("enrollment_storage")
		}
		e, err := st.GetAppAttestEnrollment(ctx, reply.EnrollmentSession)
		if err != nil || e == nil || e.Owner != x.owner || e.KeyID != id || e.AppID != x.s.appAttestShadow.AppID || e.Environment != x.s.appAttestShadow.Environment || e.AccountScope != x.accountScope() || time.Since(e.CreatedAt) > 24*time.Hour || e.CreatedAt.After(time.Now()) {
			return [32]byte{}, errors.New("enrollment_context")
		}
		// This recovers enrollment only. A fresh assertion, encrypted to the
		// new connection's actual endpoint, must still follow every reconnect.
		session, challenge, publicKey = e.ID, e.Challenge, e.PublicKey
	}
	return protocol.AppAttestShadowHashV2(action, session, x.s.appAttestShadow.Environment, id, challenge, publicKey, x.accountScope(), reply.Status), nil
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

func (x *appAttestShadowSession) machineID() string {
	if x.inventory == nil {
		return ""
	}
	return x.inventory.snapshot().ID
}
func (x *appAttestShadowSession) keyOwnerMatches(ctx context.Context, key *store.AppAttestShadowKey) bool {
	if key.Owner == x.owner {
		return true
	}
	// A claimed key ID never assigns identity. Same-account reuse must first
	// prove custody through a fresh encrypted assertion. Only after its durable
	// acceptance does inventory attach the credential alias to this session.
	if x.protocolVersion == 2 && x.account != "" && key.AccountID == x.account {
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
