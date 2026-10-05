// Package evidence archives the exact received proof field and immutable
// verification inputs before any parsing, challenge or cryptographic verdict.
package evidence

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"runtime/debug"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

type Prepared struct {
	Hash [32]byte
	Err  error
}

type Input struct {
	Binding         transcript.Binding
	Expected        string
	PreviousCounter uint32
	ReadyContext    map[string]any
}

type Entry struct {
	Evidence          store.AppAttestEvidence
	Prepared          Prepared
	UnverifiedReceipt *store.AppAttestReceipt
}

type Writer struct {
	archive     store.AppAttestArchiveStore
	enrollments store.AppAttestEnrollmentStore
	provider    *registry.Provider
}

func NewWriter(archive store.AppAttestArchiveStore, enrollments store.AppAttestEnrollmentStore, provider *registry.Provider) *Writer {
	return &Writer{archive: archive, enrollments: enrollments, provider: provider}
}

// Begin captures enrollment once and retains malformed base64 verbatim. Partial
// decode output is never presented as a complete decoded proof.
func (w *Writer) Begin(ctx context.Context, input Input, reply protocol.AppAttestShadowPayload) (Entry, error) {
	raw, decodeErr := base64.StdEncoding.DecodeString(reply.Proof)
	if decodeErr != nil {
		raw = nil
	}
	sum := sha256.Sum256([]byte(reply.Proof))
	action := "assert"
	if input.Expected == "attestation" {
		action = "attest"
	}
	keyID := reply.KeyID
	if input.Binding.KeyID != nil {
		keyID = *input.Binding.KeyID
	}
	hash, enrollment, hashErr := transcript.Prepare(ctx, w.enrollments, input.Binding, action, reply)
	inputs := map[string]any{"verifier_version": appattest.VerifierVersion, "policy_version": "mac-acl-shadow-v1", "coordinator_version": buildRevision(),
		"app_id": input.Binding.AppID, "environment": input.Binding.Environment, "shadow_session": input.Binding.Session,
		"action": action, "key_id": keyID, "challenge": input.Binding.Challenge, "public_key": input.Binding.PublicKey, "client_data_hash": hex.EncodeToString(hash[:]),
		"previous_counter": input.PreviousCounter, "account_id": input.Binding.Account, "received_session": reply.Session, "received_action": reply.Action,
		"received_key_id": reply.KeyID, "received_challenge": reply.Challenge, "client_result": reply.Result,
		"status": reply.Status, "account_scope": transcript.AccountScope(input.Binding.Account), "protocol_version": input.Binding.ProtocolVersion, "enrollment_session": reply.EnrollmentSession, "hash_context_valid": hashErr == nil,
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
	for key, value := range input.ReadyContext {
		inputs[key] = value
	}
	for key, value := range reply.RuntimeDiagnosticFields(time.Now()) {
		inputs[key] = value
	}
	inputs["proof_field_sha256"] = hex.EncodeToString(sum[:])
	inputs["proof_field_checksum_encoding"] = "proof_field_utf8"
	inputs["proof_decode_valid"] = decodeErr == nil
	if decodeErr == nil {
		rawSum := sha256.Sum256(raw)
		inputs["proof_sha256"] = hex.EncodeToString(rawSum[:])
		inputs["checksum_encoding"] = "base64_decoded_bytes"
	}
	w.provider.Mu().Lock()
	inputs["legacy_trust"] = string(w.provider.TrustLevel)
	inputs["legacy_code_attested"] = w.provider.CodeAttested
	inputs["legacy_mda_verified"] = w.provider.MDAVerified
	w.provider.Mu().Unlock()
	contextJSON, _ := json.Marshal(inputs)
	e := store.AppAttestEvidence{ID: uuid.NewString(), SessionID: w.provider.ID, KeyID: reply.KeyID, ReceivedAt: time.Now().UTC(), Action: reply.Action,
		ProofField: reply.Proof, Proof: raw, SHA256: hex.EncodeToString(sum[:]), Context: contextJSON}
	entry := Entry{Evidence: e, Prepared: Prepared{Hash: hash, Err: hashErr}}
	if err := w.archive.BeginAppAttestEvidence(ctx, e); err != nil {
		return entry, err
	}
	if receipt := appattest.ExtractReceipt(raw); action == "attest" && len(receipt) > 0 {
		entry.UnverifiedReceipt = &store.AppAttestReceipt{ID: uuid.NewString(), KeyID: reply.KeyID, EvidenceID: e.ID, ReceivedAt: e.ReceivedAt, Body: receipt, Outcome: "attestation_not_verified", Context: contextJSON, Details: json.RawMessage(`{}`)}
	}
	return entry, nil
}

func buildRevision() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			if setting.Key == "vcs.revision" {
				return setting.Value
			}
		}
	}
	return "unknown"
}
