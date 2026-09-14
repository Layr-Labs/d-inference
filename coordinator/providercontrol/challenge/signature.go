package challenge

import (
	"encoding/base64"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Verifier) verifySignatures(providerID string, provider *registry.Provider, expected Expected, resp *protocol.AttestationResponseMessage) (bool, bool) {
	// Verify the nonce matches.
	if resp.Nonce != expected.Nonce {
		s.RecordFailure(providerID, "nonce mismatch")
		return false, false
	}

	// Verify the public key matches the registered key.
	if provider.PublicKey != "" && resp.PublicKey != provider.PublicKey {
		s.RecordFailure(providerID, "public key mismatch")
		return false, false
	}

	// Verify the signature cryptographically using the provider's Secure
	// Enclave P-256 public key. The provider signs SHA-256(nonce + timestamp)
	// with its SE key via eigeninference-enclave CLI.
	if resp.Signature == "" {
		s.RecordFailure(providerID, "empty signature")
		return false, false
	}

	// statusFieldsTrusted gates whether we treat resp.SIPEnabled,
	// resp.BinaryHash etc. as authoritative. False means the provider
	// signed only nonce+timestamp (legacy or downgrade), so the status
	// fields are advisory and we must not act on them as if they were
	// cryptographically bound.
	statusFieldsTrusted := false

	// If the provider has an attested SE public key, verify the signature.
	// Providers without attestation (TrustNone / Open Mode) skip crypto
	// verification — their trust is already "none".
	if provider.AttestationResult != nil && provider.AttestationResult.PublicKey != "" {
		challengeData := expected.Nonce + expected.Timestamp
		if err := attestation.VerifyChallengeSignature(
			provider.AttestationResult.PublicKey,
			resp.Signature,
			challengeData,
		); err != nil {
			s.deps.Logger().Error("challenge signature verification failed",
				"provider_id", providerID,
				"error", err,
			)
			s.RecordFailure(providerID, "signature verification failed: "+err.Error())
			return false, false
		}

		// Now verify the extended status signature if the provider sent
		// one. Old providers (pre-v0.3.11) won't — log and continue with
		// status fields untrusted. Mismatch is fatal: it means either
		// tampering or the provider is signing a different canonical
		// payload than this code expects.
		statusInput := attestation.StatusCanonicalInput{
			Nonce:     expected.Nonce,
			Timestamp: expected.Timestamp,
			// Legacy fleet compat only: old providers (< v0.6.31) sign
			// hypervisor_active into the canonical status, so it must be
			// carried into the reconstruction when reported. New providers
			// omit it (nil). See attestation.StatusCanonicalInput.
			HypervisorActive:  resp.HypervisorActive,
			RDMADisabled:      resp.RDMADisabled,
			SIPEnabled:        resp.SIPEnabled,
			SecureBootEnabled: resp.SecureBootEnabled,
			BinaryHash:        resp.BinaryHash,
			ActiveModelHash:   resp.ActiveModelHash,
			PythonHash:        resp.PythonHash,
			RuntimeHash:       resp.RuntimeHash,
			TemplateHashes:    resp.TemplateHashes,
			ModelHashes:       resp.ModelHashes,
		}
		switch err := attestation.VerifyStatusSignature(
			provider.AttestationResult.PublicKey,
			resp.StatusSignature,
			statusInput,
		); err {
		case nil:
			statusFieldsTrusted = true
		case attestation.ErrStatusSignatureMissing:
			s.deps.Incr("attestation.challenges", []string{"outcome:status_sig_missing"})
			s.deps.Logger().Warn("provider sent no status_signature — status fields are advisory; upgrade provider to bind them",
				"provider_id", providerID,
			)
		default:
			// Instrumentation for the non-recovering status-sig lockout seen on
			// a couple of nodes (cause unconfirmed). Because the plain challenge
			// signature already verified above (we returned on its failure),
			// reaching here isolates the status-sig / canonical path: log
			// plain_sig_passed plus the Go canonical bytes and per-field lengths
			// so a field-presence or canonicalization mismatch is diagnosable
			// from logs alone, without shipping a new build to the affected box.
			canonical, cerr := attestation.BuildStatusCanonical(statusInput)
			canonicalB64 := ""
			if cerr == nil {
				canonicalB64 = base64.StdEncoding.EncodeToString(canonical)
			}
			s.deps.Incr("attestation.challenges", []string{"outcome:status_sig_failed"})
			if s.deps.Counters() != nil {
				s.deps.Counters().IncCounter("attestation_status_sig_failed_total")
			}
			s.deps.Logger().Error("status signature verification failed — possible tampering or canonical mismatch",
				"provider_id", providerID,
				"error", err,
				"plain_sig_passed", true,
				"go_canonical_b64", canonicalB64,
				"go_canonical_len", len(canonical),
				"canonical_build_err", cerr,
				"status_sig_len", len(resp.StatusSignature),
				"binary_hash_len", len(resp.BinaryHash),
				"active_model_hash_len", len(resp.ActiveModelHash),
				"python_hash_len", len(resp.PythonHash),
				"runtime_hash_len", len(resp.RuntimeHash),
				"template_hashes_count", len(resp.TemplateHashes),
				"model_hashes_count", len(resp.ModelHashes),
			)
			s.RecordFailure(providerID, "status signature verification failed: "+err.Error())
			return false, false
		}
	}

	// Status-field enforcement policy (asymmetric, by design):
	//
	// The checks below act on resp.SIPEnabled / SecureBootEnabled /
	// RDMADisabled / BinaryHash / ActiveModelHash regardless of
	// statusFieldsTrusted. The asymmetry is intentional during the
	// v0.3.11 rollout window:
	//
	//   - Negative reports (SIP=false, hash mismatch, etc.) ALWAYS mark
	//     the provider untrusted. Acting on a negative is safe even if
	//     the field is spoofable: the worst case is a compromised
	//     provider DoS-ing itself, which we want anyway.
	//
	//   - Positive reports (SIP=true, hash matches) are accepted but
	//     can only be fully trusted when statusFieldsTrusted is true.
	//     A v0.3.10 provider with a compromised process (but intact SE
	//     key) can echo a valid nonce signature while lying that
	//     SIPEnabled=true. We accept this risk during rollout.
	//
	// TODO(security/v0.3.13+): Once `attestation_challenges_total{
	// outcome="status_sig_missing"}` is zero across the fleet for a
	// week, treat ErrStatusSignatureMissing as a hard challenge failure
	// (target: 2 release cycles after v0.3.11 GA).
	s.deps.Logger().Debug("attestation challenge response verified",
		"provider_id", providerID,
		"status_fields_trusted", statusFieldsTrusted,
	)

	return statusFieldsTrusted, true
}
