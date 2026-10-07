// Package exchange executes the App Attest reply protocol against one issued
// challenge. Archive admission and worker scheduling belong to its caller.
package exchange

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/receipt"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Challenge contains only the immutable inputs of this exchange, not worker or
// service state. The prepared hash is the snapshot already retained by archive.
type Challenge struct {
	Binding               transcript.Binding
	Expected              string
	Started               time.Time
	Credential            *store.AppAttestShadowKey
	Prepared              *evidence.Prepared
	EvidenceID, MachineID string
}

type Dependencies struct {
	Keys         store.AppAttestShadowStore
	Verifier     *appattest.Verifier
	OwnerMatches func(context.Context, *store.AppAttestShadowKey) bool
	Rotate       func(context.Context, *store.AppAttestShadowKey) bool
	Commit       func(context.Context, store.AppAttestDecision) bool
	Observe      func(string, string, *appattest.Key, protocol.AppAttestShadowPayload)
	ReceiptNow   func() time.Time
	MachineID    func() string
}

type Result struct {
	Next              string
	Credential        *store.AppAttestShadowKey
	Owner             string
	ReadyObserved     bool
	ReadyContext      map[string]any
	AssertionAt       time.Time
	AssertionMetadata *appattest.Key
}

func Verify(ctx context.Context, deps Dependencies, c Challenge, reply protocol.AppAttestShadowPayload) Result {
	r := Result{Next: "stop"}
	observe := func(stage, outcome string, metadata *appattest.Key) {
		if deps.Observe != nil {
			deps.Observe(stage, outcome, metadata, protocol.AppAttestShadowPayload{})
		}
	}
	if !c.Started.IsZero() && time.Since(c.Started) > recovery.ResponseTimeout {
		observe(c.Expected, "timeout", nil)
		return r
	}
	if c.Expected == "ready" {
		r.ReadyObserved, r.ReadyContext = true, reply.RuntimeDiagnosticFields(time.Now())
	}
	if reply.Result != "ok" {
		if deps.Observe != nil {
			deps.Observe(c.Expected, recovery.ClientResult(reply.Result), nil, reply)
		}
		return r
	}
	if c.Expected == "ready" {
		id, err := base64.StdEncoding.DecodeString(reply.KeyID)
		if err != nil || len(id) != 32 || base64.StdEncoding.EncodeToString(id) != reply.KeyID {
			observe("ready", "key_id", nil)
			return r
		}
		if deps.Observe != nil {
			deps.Observe("ready", "reported_supported", nil, reply)
		}
		key, err := deps.Keys.GetAppAttestShadowKey(ctx, reply.KeyID)
		if err != nil {
			observe("ready", "storage_error", nil)
			return r
		}
		if key == nil {
			r.Credential, r.Next = &store.AppAttestShadowKey{KeyID: reply.KeyID}, "attest"
			return r
		}
		if !deps.OwnerMatches(ctx, key) || key.Environment != c.Binding.Environment || key.AppID != c.Binding.AppID {
			observe("ready", "key_owner_or_policy", nil)
			return r
		}
		r.Credential, r.Owner = key, key.Owner
		if deps.Rotate != nil && deps.Rotate(ctx, key) {
			r.Next = "attest"
		} else {
			r.Next = "assert"
		}
		return r
	}
	if c.Credential == nil || reply.KeyID != c.Credential.KeyID || reply.Challenge != c.Binding.Challenge {
		observe(c.Expected, "challenge_mismatch", nil)
		return r
	}
	proof, err := base64.StdEncoding.DecodeString(reply.Proof)
	if err != nil {
		observe(c.Expected, "malformed_proof", nil)
		return r
	}
	action := "assert"
	if c.Expected == "attestation" {
		action = "attest"
	}
	if c.Prepared == nil {
		observe(c.Expected, "enrollment_context", nil)
		return r
	}
	hash, err := c.Prepared.Hash, c.Prepared.Err
	if err != nil {
		reason := "enrollment_context"
		switch err.Error() {
		case "enrollment_storage_error", "enrollment_expired":
			reason = err.Error()
		}
		observe(c.Expected, reason, nil)
		return r
	}
	if action == "attest" {
		verified, err := deps.Verifier.Attestation(proof, c.Credential.KeyID, hash)
		if err != nil {
			observe("attestation", err.Error(), nil)
			return r
		}
		machineID := c.MachineID
		if deps.MachineID != nil {
			machineID = deps.MachineID()
		}
		r.Credential = &store.AppAttestShadowKey{KeyID: c.Credential.KeyID, Owner: c.Binding.Owner, AccountID: c.Binding.Account, MachineID: machineID,
			PublicKey: verified.PublicKey, AppID: c.Binding.AppID, Environment: c.Binding.Environment, BundleVersion: verified.BundleVersion, ValidationCategory: verified.ValidationCategory}
		details, _ := json.Marshal(map[string]any{"bundle_version": verified.BundleVersion, "validation_category": verified.ValidationCategory,
			"code_directory_hash": hex.EncodeToString(verified.CodeDirectoryHash), "code_directory_type": verified.CodeDirectoryType})
		now := time.Now
		if deps.ReceiptNow != nil {
			now = deps.ReceiptNow
		}
		initial := receipt.EnrollmentRecord(r.Credential, c.EvidenceID, proof, hash, now())
		if !deps.Commit(ctx, store.AppAttestDecision{Outcome: "verified", Key: r.Credential, Receipt: initial, Details: details}) {
			return r
		}
		observe("attestation", "verified", verified)
		r.Next = "assert"
		return r
	}
	counter, metadata, err := deps.Verifier.Assertion(proof, c.Credential.PublicKey, hash, c.Credential.Counter)
	if err != nil {
		observe("assertion", err.Error(), nil)
		return r
	}
	details, _ := json.Marshal(map[string]any{"received_counter": counter, "bundle_version": metadata.BundleVersion, "validation_category": metadata.ValidationCategory,
		"code_directory_hash": hex.EncodeToString(metadata.CodeDirectoryHash), "code_directory_type": metadata.CodeDirectoryType})
	if !deps.Commit(ctx, store.AppAttestDecision{Outcome: "verified", Counter: &counter, KeyID: c.Credential.KeyID, Owner: c.Binding.Owner, Details: details}) {
		return r
	}
	c.Credential.Counter = counter
	c.Credential.UpdatedAt = time.Now().UTC()
	r.AssertionAt = time.Now().UTC()
	r.AssertionMetadata = metadata
	observe("assertion", "verified", metadata)
	r.Next = "wait"
	return r
}
