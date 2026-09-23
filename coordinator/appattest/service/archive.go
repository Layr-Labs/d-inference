package service

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"runtime/debug"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (x *Session) handle(ctx context.Context, reply protocol.AppAttestShadowPayload) string {
	release, ok := x.acquireStorage()
	if !ok {
		x.lastOutcome = "storage_busy"
		x.markDropped()
		x.observe("archive", "storage_busy", nil)
		return "stop"
	}
	// Registered first so the permit is released AFTER deferred completion.
	defer release()
	if x.archive == nil {
		x.archive, _ = store.As[store.AppAttestArchiveStore](x.store)
	}
	var prepared *shadowProofContext
	// Every admitted proof is archived before parsing, challenge checks, or
	// cryptographic verification. Invalid base64 is retained verbatim too.
	if reply.Proof != "" || reply.Action == "attestation" || reply.Action == "assertion" || x.expected == "attestation" || x.expected == "assertion" {
		if x.archive == nil {
			x.markDropped()
			x.observe("archive", "unavailable", nil)
			return "stop"
		}
		raw, decodeErr := base64.StdEncoding.DecodeString(reply.Proof)
		if decodeErr != nil {
			// Partial decode output is not a complete proof. The exact original
			// field and its checksum remain available for malformed submissions.
			raw = nil
		}
		sum := sha256.Sum256([]byte(reply.Proof))
		action := "assert"
		if x.expected == "attestation" {
			action = "attest"
		}
		keyID := reply.KeyID
		previous := uint32(0)
		if x.key != nil {
			keyID = x.key.KeyID
			previous = x.key.Counter
		}
		hash, enrollment, hashErr := x.prepareClientHash(ctx, action, reply)
		prepared = &shadowProofContext{Hash: hash, Err: hashErr}
		inputs := map[string]any{"verifier_version": appattest.VerifierVersion, "policy_version": "mac-acl-shadow-v1", "coordinator_version": coordinatorBuildRevision(),
			"app_id": x.s.config.AppID, "environment": x.s.config.Environment, "shadow_session": x.id,
			"action": action, "key_id": keyID, "challenge": x.challenge, "public_key": x.publicKey, "client_data_hash": hex.EncodeToString(hash[:]),
			"previous_counter": previous, "account_id": x.account, "received_session": reply.Session, "received_action": reply.Action,
			"received_key_id": reply.KeyID, "received_challenge": reply.Challenge, "client_result": reply.Result,
			"status": reply.Status, "account_scope": x.accountScope(), "protocol_version": x.protocolVersion, "enrollment_session": reply.EnrollmentSession, "hash_context_valid": hashErr == nil,
			"root_sha256": appattest.RootSHA256(), "evaluated_at": time.Now().UTC()}
		if enrollment != nil {
			inputs["enrollment_context"] = enrollment
		}
		if reply.AppleError != nil && reply.AppleError.Valid() {
			inputs["apple_error"] = reply.AppleError
		}
		if reply.ValidClientDiagnostics() {
			if reply.AvailabilityReason != "" {
				inputs["availability_reason"] = reply.AvailabilityReason
			}
			if reply.AppleErrorSource != "" {
				inputs["apple_error_source"] = reply.AppleErrorSource
			}
		}
		inputs["proof_field_sha256"] = hex.EncodeToString(sum[:])
		inputs["proof_field_checksum_encoding"] = "proof_field_utf8"
		inputs["proof_decode_valid"] = decodeErr == nil
		if decodeErr == nil {
			rawSum := sha256.Sum256(raw)
			inputs["proof_sha256"] = hex.EncodeToString(rawSum[:])
			inputs["checksum_encoding"] = "base64_decoded_bytes"
		}
		x.provider.Mu().Lock()
		inputs["legacy_trust"] = string(x.provider.TrustLevel)
		inputs["legacy_code_attested"] = x.provider.CodeAttested
		inputs["legacy_mda_verified"] = x.provider.MDAVerified
		x.provider.Mu().Unlock()
		contextJSON, _ := json.Marshal(inputs)
		x.evidenceID = uuid.NewString()
		x.evidenceOutcome = "rejected"
		e := store.AppAttestEvidence{ID: x.evidenceID, SessionID: x.provider.ID, KeyID: reply.KeyID, ReceivedAt: time.Now().UTC(), Action: reply.Action,
			ProofField: reply.Proof, Proof: raw, SHA256: hex.EncodeToString(sum[:]), Context: contextJSON}
		if err := x.archive.BeginAppAttestEvidence(ctx, e); err != nil {
			x.markDropped()
			x.lastOutcome = "write_failed"
			x.evidenceID = ""
			x.observe("archive", "write_failed", nil)
			return "stop"
		}
		var unverifiedReceipt *store.AppAttestReceipt
		if receipt := appattest.ExtractReceipt(raw); action == "attest" && len(receipt) > 0 {
			unverifiedReceipt = &store.AppAttestReceipt{ID: uuid.NewString(), KeyID: reply.KeyID, EvidenceID: x.evidenceID, ReceivedAt: e.ReceivedAt, Body: receipt, Outcome: "attestation_not_verified", Context: contextJSON, Details: json.RawMessage(`{}`)}
		}
		x.s.ddIncr("app_attest.archive.received", nil)
		defer func() {
			if x.evidenceID != "" {
				final, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				if outcome, err := x.archive.CompleteAppAttestEvidence(final, x.evidenceID, store.AppAttestDecision{Outcome: x.evidenceOutcome, Receipt: unverifiedReceipt}); err != nil {
					x.markDropped()
					x.observe("archive", "completion_failed", nil)
				} else {
					x.s.ddIncr("app_attest.archive.completed", []string{"outcome:" + outcome})
				}
				x.evidenceID = ""
			}
		}()
	}
	// An unsolicited or wrong-session proof still has an audit record.
	if reply.Session != x.id || reply.Action != x.expected {
		x.observe("protocol", "unexpected_reply", nil)
		if x.expected == "" && reply.Session == x.id {
			// A delayed duplicate from the previous challenge has no power
			// to satisfy a new one. Keep the scheduled assertion deadline.
			return "ignore"
		}
		return "stop"
	}
	if x.rejectReason != "" {
		x.lastOutcome = x.rejectReason
		x.observe("archive", x.rejectReason, nil)
		x.evidenceOutcome = x.rejectReason
		return "stop"
	}
	return x.handleExchange(ctx, reply, prepared)
}

func (x *Session) commitEvidence(ctx context.Context, d store.AppAttestDecision) bool {
	if x.archive == nil || x.evidenceID == "" {
		x.markDropped()
		x.observe("archive", "unavailable", nil)
		return false
	}
	outcome, err := x.archive.CompleteAppAttestEvidence(ctx, x.evidenceID, d)
	if err != nil {
		x.markDropped()
		x.evidenceOutcome = "storage_error"
		x.lastOutcome = "storage_error"
		x.observe("archive", "completion_failed", nil)
		return false
	}
	x.evidenceID = ""
	x.s.ddIncr("app_attest.archive.completed", []string{"outcome:" + outcome})
	if outcome != "verified" {
		if x.expected == "assertion" && x.s.authorizer != nil {
			// The rejected proof is retained, but the older serving proof must
			// not remain active after an assertion counter/commit conflict.
			x.s.authorizer.forget(x.provider)
		}
		x.observe(x.expected, outcome, nil)
		return false
	}
	if x.expected == "assertion" {
		x.assertionArchived = true
	}
	return true
}

func coordinatorBuildRevision() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			if setting.Key == "vcs.revision" {
				return setting.Value
			}
		}
	}
	return "unknown"
}

func (x *Session) closeAndArchivePending() {
	x.offerMu.Lock()
	x.closed.Store(true)
	x.offerMu.Unlock()
	x.rejectReason = "session_stopped"
	for {
		select {
		case reply := <-x.in:
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			x.handle(ctx, reply)
			cancel()
		default:
			return
		}
	}
}
