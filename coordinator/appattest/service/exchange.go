package service

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

func (x *Session) send(ctx context.Context, action string) bool {
	var nonce [32]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		x.observe(action, "internal_error", nil)
		return false
	}
	x.challenge = base64.StdEncoding.EncodeToString(nonce[:])
	p := protocol.AppAttestShadowPayload{Action: action, Session: x.id, Environment: x.s.config.Environment}
	x.expected = map[string]string{"prepare": "ready", "attest": "attestation", "assert": "assertion"}[action]
	if x.key != nil {
		p.KeyID = x.key.KeyID
	}
	if x.protocolVersion >= 2 {
		p.ProtocolVersion = x.protocolVersion
		p.AccountScope = x.accountScope()
	}
	if action == "attest" {
		p.Challenge = x.challenge
		if x.protocolVersion >= 2 {
			enrollments, ok := store.As[store.AppAttestEnrollmentStore](x.s.store)
			if !ok {
				x.observe(action, "storage_unavailable", nil)
				return false
			}
			release, ok := x.acquireStorage()
			if !ok {
				x.observe(action, "storage_busy", nil)
				return false
			}
			operation, cancel := context.WithTimeout(ctx, 2*time.Second)
			err := enrollments.SaveAppAttestEnrollment(operation, store.AppAttestEnrollment{ProtocolVersion: x.protocolVersion, ID: x.id, Owner: x.owner, KeyID: x.key.KeyID, CreatedAt: time.Now().UTC(), Environment: x.s.config.Environment, AppID: x.s.config.AppID, Challenge: x.challenge, PublicKey: x.publicKey, AccountScope: x.accountScope()})
			cancel()
			release()
			if err != nil {
				x.observe(action, "storage_error", nil)
				return false
			}
		}
	}
	if action == "assert" {
		pub, err := base64.StdEncoding.DecodeString(x.publicKey)
		if err != nil || len(pub) != 32 {
			x.observe(action, "encryption_key", nil)
			return false
		}
		keys, err := e2e.GenerateSessionKeys()
		if err != nil {
			x.observe(action, "internal_error", nil)
			return false
		}
		var recipient [32]byte
		copy(recipient[:], pub)
		payload, err := e2e.Encrypt([]byte(x.challenge), recipient, keys)
		if err != nil {
			x.observe(action, "internal_error", nil)
			return false
		}
		p.EncryptedChallenge = &protocol.EncryptedPayload{EphemeralPublicKey: payload.EphemeralPublicKey, Ciphertext: payload.Ciphertext}
	}
	data, _ := json.Marshal(protocol.AppAttestShadowMessage{Type: protocol.TypeAppAttestShadow, Payload: p})
	x.started = time.Now()
	if err := x.provider.EnqueueText(ctx, data); err != nil {
		x.observe(action, "send_failed", nil)
		return false
	}
	x.observe(action, "attempted", nil)
	return true
}

func (x *Session) handleExchange(ctx context.Context, reply protocol.AppAttestShadowPayload, prepared *shadowProofContext) string {
	// Timer and inbox can become ready together; never let select ordering
	// count a late proof as a timely success.
	if !x.started.IsZero() && time.Since(x.started) > shadowResponseTimeout {
		x.observe(x.expected, "timeout", nil)
		return "stop"
	}
	if reply.Result != "ok" {
		x.observeWithAppleError(x.expected, shadowClientResult(reply.Result), nil, reply.AppleError)
		return "stop"
	}
	if x.expected == "ready" {
		id, err := base64.StdEncoding.DecodeString(reply.KeyID)
		if err != nil || len(id) != 32 || base64.StdEncoding.EncodeToString(id) != reply.KeyID {
			x.observe("ready", "key_id", nil)
			return "stop"
		}
		x.observe("ready", "reported_supported", nil)
		key, err := x.store.GetAppAttestShadowKey(ctx, reply.KeyID)
		if err != nil {
			x.observe("ready", "storage_error", nil)
			return "stop"
		}
		if key == nil {
			x.key = &store.AppAttestShadowKey{KeyID: reply.KeyID}
			return "attest"
		}
		if !x.keyOwnerMatches(ctx, key) || key.Environment != x.s.config.Environment || key.AppID != x.s.config.AppID {
			x.observe("ready", "key_owner_or_policy", nil)
			return "stop"
		}
		x.key = key
		x.owner = key.Owner
		return "assert"
	}
	if x.key == nil || reply.KeyID != x.key.KeyID || reply.Challenge != x.challenge {
		x.observe(x.expected, "challenge_mismatch", nil)
		return "stop"
	}
	proof, err := base64.StdEncoding.DecodeString(reply.Proof)
	if err != nil {
		x.observe(x.expected, "malformed_proof", nil)
		return "stop"
	}
	action := "assert"
	if x.expected == "attestation" {
		action = "attest"
	}
	if prepared == nil {
		x.observe(x.expected, "enrollment_context", nil)
		return "stop"
	}
	hash, err := prepared.Hash, prepared.Err
	if err != nil {
		reason := "enrollment_context"
		switch err.Error() {
		case "enrollment_storage_error", "enrollment_expired":
			reason = err.Error()
		}
		x.observe(x.expected, reason, nil)
		return "stop"
	}
	if action == "attest" {
		verified, err := x.verifier.Attestation(proof, x.key.KeyID, hash)
		if err != nil {
			x.observe("attestation", err.Error(), nil)
			return "stop"
		}
		x.key = &store.AppAttestShadowKey{KeyID: x.key.KeyID, Owner: x.owner, AccountID: x.account, MachineID: x.machineID(), PublicKey: verified.PublicKey, AppID: x.s.config.AppID,
			Environment: x.s.config.Environment, BundleVersion: verified.BundleVersion, ValidationCategory: verified.ValidationCategory}
		details, _ := json.Marshal(map[string]any{"bundle_version": verified.BundleVersion, "validation_category": verified.ValidationCategory,
			"code_directory_hash": hex.EncodeToString(verified.CodeDirectoryHash), "code_directory_type": verified.CodeDirectoryType})
		if !x.commitEvidence(ctx, store.AppAttestDecision{Outcome: "verified", Key: x.key, Receipt: x.initialReceipt(proof, hash), Details: details}) {
			return "stop"
		}
		x.observe("attestation", "verified", verified)
		return "assert"
	}
	counter, metadata, err := x.verifier.Assertion(proof, x.key.PublicKey, hash, x.key.Counter)
	if err != nil {
		x.observe("assertion", err.Error(), nil)
		return "stop"
	}
	details, _ := json.Marshal(map[string]any{"received_counter": counter, "bundle_version": metadata.BundleVersion, "validation_category": metadata.ValidationCategory,
		"code_directory_hash": hex.EncodeToString(metadata.CodeDirectoryHash), "code_directory_type": metadata.CodeDirectoryType})
	if !x.commitEvidence(ctx, store.AppAttestDecision{Outcome: "verified", Counter: &counter, KeyID: x.key.KeyID, Owner: x.owner, Details: details}) {
		return "stop"
	}
	x.key.Counter = counter
	x.assertionAt = time.Now().UTC()
	x.observe("assertion", "verified", metadata)
	x.observeBuildPolicy(reply.Status, metadata)
	return "wait"
}

func shadowClientResult(value string) string {
	switch value {
	case "unsupported", "not_configured", "environment_mismatch", "keychain_error", "apple_unavailable", "apple_invalid_key", "apple_error", "key_unregistered", "busy", "cancelled", "decryption_failed", "invalid_request", "operation_timeout":
		return value
	}
	return "client_error"
}
