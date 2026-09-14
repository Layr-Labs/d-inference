package challenge

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Verifier) verifyBinaryHash(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage) bool {
	// Verify fresh binary hash when a known-good policy is configured. A
	// reported binary hash only counts when the response is signed by the
	// provider key from a valid registration attestation.
	//
	// v0.6.0: binaryHash is self-reported and demoted to drift telemetry — APNs
	// code-identity attestation is the real code-identity signal — so this gate
	// deroutes a provider only when enforcement is explicitly enabled (rollback).
	policyConfigured, knownBinaryHashes := s.deps.BinaryHashPolicy()
	if s.deps.EnforceBinaryHash() && policyConfigured {
		attestationResult := provider.AttestationResult
		if attestationResult == nil || !attestationResult.Valid || attestationResult.PublicKey == "" {
			s.deps.Logger().Error("provider cannot prove binary hash without valid attestation",
				"provider_id", providerID,
			)
			s.deps.Registry().MarkUntrusted(providerID)
			s.RecordFailure(providerID, "valid attestation required for binary hash policy")
			return false
		}
		if resp.BinaryHash == "" {
			s.deps.Logger().Error("provider omitted binary hash while known-good policy is configured",
				"provider_id", providerID,
			)
			s.deps.Registry().MarkUntrusted(providerID)
			s.RecordFailure(providerID, "binary hash missing")
			return false
		}
		attestedBinaryHash, err := s.deps.NormalizeHash(attestationResult.BinaryHash, "attested binary_hash")
		if err != nil {
			s.deps.Logger().Error("provider attestation has no usable binary hash",
				"provider_id", providerID,
				"binary_hash", attestationResult.BinaryHash,
			)
			s.deps.Registry().MarkUntrusted(providerID)
			s.RecordFailure(providerID, "attested binary hash missing")
			return false
		}
		binaryHash, err := s.deps.NormalizeHash(resp.BinaryHash, "binary_hash")
		if err != nil || !knownBinaryHashes[binaryHash] {
			s.deps.Logger().Error("provider binary hash changed — no longer matches known-good list",
				"provider_id", providerID,
				"binary_hash", resp.BinaryHash,
			)
			s.deps.Registry().MarkUntrusted(providerID)
			s.RecordFailure(providerID, "binary hash mismatch")
			return false
		}
		if binaryHash != attestedBinaryHash {
			s.deps.Logger().Error("provider binary hash changed from registration attestation",
				"provider_id", providerID,
				"attested_binary_hash", registry.TruncHash(attestedBinaryHash),
				"challenge_binary_hash", registry.TruncHash(binaryHash),
			)
			s.deps.Registry().MarkUntrusted(providerID)
			s.RecordFailure(providerID, "binary hash changed from registration attestation")
			return false
		}
	}

	return true
}

func (s *Verifier) verifyModelHashes(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage) bool {
	// Verify reported model weight hashes against the catalog. The response's
	// model_hashes map is keyed by model ID, so each entry is compared against
	// the catalog hash for exactly that model — race-free, and strictly
	// stronger than checking only the active model.
	//
	// The previous check compared resp.ActiveModelHash (the hash of whatever
	// model the PROVIDER considered current when it built the response)
	// against the catalog hash of provider.CurrentModel (the model the
	// COORDINATOR believed current, from the last heartbeat — up to a full
	// heartbeat interval stale). On a busy multi-model provider the current
	// model flips between heartbeats, so the two regularly disagreed and a
	// perfectly correct hash of model B was misread as a tampered hash of
	// model A ("possible model swap") → false hard-untrust. Hit in prod by
	// the two busiest dual-model boxes (gemma-4-26b + gpt-oss-20b interleaved).
	for modelID, hash := range resp.ModelHashes {
		if hash == "" {
			continue
		}
		expectedHash := s.deps.Registry().CatalogWeightHash(modelID)
		if expectedHash != "" && hash != expectedHash {
			s.deps.Logger().Error("provider model weight hash mismatch — possible model swap",
				"provider_id", providerID,
				"model", modelID,
				"expected", registry.TruncHash(expectedHash),
				"got", registry.TruncHash(hash),
			)
			s.deps.Registry().MarkUntrusted(providerID)
			s.RecordFailure(providerID, "model weight hash mismatch")
			return false
		}
	}

	// The bare active_model_hash names no model, so the strongest race-free
	// statement it admits is membership: when EVERY advertised model has an
	// enforced catalog hash, a hash that matches none of them is tampered.
	// This runs regardless of model_hashes — a map holding only empty or
	// unknown entries must not suppress it — and stays inconclusive (skipped)
	// when any advertised model is unenforced, since the bare hash could
	// legitimately belong to that model. (Comparing against the
	// heartbeat-derived "current model" instead is inherently racy — see
	// above.)
	if resp.ActiveModelHash != "" {
		provider.Mu().Lock()
		models := provider.Models
		provider.Mu().Unlock()
		allEnforced := len(models) > 0
		matched := false
		for _, m := range models {
			expectedHash := s.deps.Registry().CatalogWeightHash(m.ID)
			if expectedHash == "" {
				allEnforced = false
				break
			}
			if resp.ActiveModelHash == expectedHash {
				matched = true
			}
		}
		// Alias hot-swap (v0.6.x): a hard-swapped build can stay GPU-resident —
		// and remain the provider's "active" model — AFTER it leaves the
		// advertised set (the retired slot drains via the idle monitor, up to
		// an hour). Its hash still arrives in model_hashes, where the per-model
		// loop above already proved it matches its own catalog entry. Such a
		// validated, registered build is a legitimate alibi for the bare active
		// hash — NOT a swap. Without this, every provider hard-untrusts at its
		// first post-swap challenge until a request lands on the new build.
		// A genuinely tampered hash still matches neither the advertised set
		// nor any catalog-validated reported hash, and still untrusts.
		if !matched {
			for modelID, hash := range resp.ModelHashes {
				if hash == "" || hash != resp.ActiveModelHash {
					continue
				}
				// Scope the alibi to the actual migration case: modelID must be a
				// PREVIOUS/RETIRED member of some alias (a build a hot-swap leaves
				// resident after de-advertising it), not just any catalog model.
				// This keeps the membership check tight — a provider can't name an
				// arbitrary unrelated catalog model as "active" to dodge it.
				if !s.deps.Registry().IsAliasLineageBuild(modelID) {
					continue
				}
				if expected := s.deps.Registry().CatalogWeightHash(modelID); expected != "" && hash == expected {
					matched = true
					break
				}
			}
		}
		if allEnforced && !matched {
			s.deps.Logger().Error("provider active model hash matches no advertised model — possible model swap",
				"provider_id", providerID,
				"got", registry.TruncHash(resp.ActiveModelHash),
			)
			s.deps.Registry().MarkUntrusted(providerID)
			s.RecordFailure(providerID, "active model weight hash mismatch")
			return false
		}
	}

	return true
}
