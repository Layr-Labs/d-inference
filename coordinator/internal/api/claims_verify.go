package api

// Signed-claims verification helpers.
//
// A provider sends every integrity-bearing field (binary_hash, runtime_hash,
// model weight hashes, wallet address, sip/secureboot/rdma flags, …) inside
// Register and AttestationResponse messages. Each message also carries a
// `claims_signature` over the canonical JSON encoding of those fields.
//
// `verifyRegisterClaims` and `verifyChallengeClaims` re-derive the canonical
// bytes from what was received, then verify the signature against the
// provider's Secure Enclave public key (P-256 ECDSA, DER signature, base64
// over both).
//
// If verification fails, the coordinator must NOT trust the claim — the
// caller should reset the corresponding fields to "unverified" defaults
// (drop trust to none, mark runtime unverified, etc.). This is the only
// thing standing between us and a malicious provider that lies about every
// integrity field with a one-line patch to its binary.

import (
	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/protocol"
)

// verifyRegisterClaims verifies the SE-signed claims envelope on a Register
// message. Returns nil on success, or a descriptive error.
//
// `sePublicKey` is the base64-encoded raw P-256 public key from the
// attestation blob. The caller MUST source this from the verified
// attestation, never from the same Register message it's verifying.
func verifyRegisterClaims(sePublicKey string, regMsg *protocol.RegisterMessage) error {
	if sePublicKey == "" {
		return errClaimsNoSEKey
	}
	if regMsg.ClaimsSignature == "" {
		return errClaimsMissing
	}
	if regMsg.ClaimsTimestamp == "" {
		return errClaimsMissingTimestamp
	}
	c := protocol.RegisterClaims{
		Timestamp:       regMsg.ClaimsTimestamp,
		Backend:         regMsg.Backend,
		Version:         regMsg.Version,
		PublicKey:       regMsg.PublicKey,
		WalletAddress:   regMsg.WalletAddress,
		AuthToken:       regMsg.AuthToken,
		PythonHash:      regMsg.PythonHash,
		RuntimeHash:     regMsg.RuntimeHash,
		GrpcBinaryHash:  regMsg.GrpcBinaryHash,
		ImageBridgeHash: regMsg.ImageBridgeHash,
		TemplateHashes:  regMsg.TemplateHashes,
		ModelHashes:     regMsg.ModelHashes,
		// Benchmark fields are not yet sent; reserved.
		PrefillTPSMilli: 0,
		DecodeTPSMilli:  0,
	}
	canonical := protocol.CanonicalRegisterJSON(c)
	return attestation.VerifyChallengeSignature(
		sePublicKey,
		regMsg.ClaimsSignature,
		string(canonical),
	)
}

// verifyChallengeClaims verifies the SE-signed claims envelope on an
// AttestationResponse. Returns nil on success.
func verifyChallengeClaims(sePublicKey string, expectedNonce, expectedTimestamp string, resp *protocol.AttestationResponseMessage) error {
	if sePublicKey == "" {
		return errClaimsNoSEKey
	}
	if resp.ClaimsSignature == "" {
		return errClaimsMissing
	}
	// Bind the envelope to the exact challenge the coordinator sent. A
	// provider that captures another device's signed envelope cannot replay
	// it because nonce + timestamp are mixed into the signed bytes.
	if resp.Nonce != expectedNonce {
		return errClaimsNonceMismatch
	}
	if resp.ClaimsTimestamp != expectedTimestamp {
		return errClaimsTimestampMismatch
	}
	c := protocol.ChallengeClaims{
		Nonce:             resp.Nonce,
		Timestamp:         resp.ClaimsTimestamp,
		BinaryHash:        resp.BinaryHash,
		ActiveModelHash:   resp.ActiveModelHash,
		PythonHash:        resp.PythonHash,
		RuntimeHash:       resp.RuntimeHash,
		GrpcBinaryHash:    resp.GrpcBinaryHash,
		ImageBridgeHash:   resp.ImageBridgeHash,
		TemplateHashes:    resp.TemplateHashes,
		ModelHashes:       resp.ModelHashes,
		SIPEnabled:        boolOrFalse(resp.SIPEnabled),
		SecureBootEnabled: boolOrFalse(resp.SecureBootEnabled),
		RDMADisabled:      boolOrFalse(resp.RDMADisabled),
		HypervisorActive:  boolOrFalse(resp.HypervisorActive),
	}
	canonical := protocol.CanonicalChallengeJSON(c)
	return attestation.VerifyChallengeSignature(
		sePublicKey,
		resp.ClaimsSignature,
		string(canonical),
	)
}

func boolOrFalse(b *bool) bool {
	return b != nil && *b
}

// Sentinel errors are simple values so callers can distinguish missing vs
// invalid signatures without string matching.
type claimsErr string

func (e claimsErr) Error() string { return string(e) }

const (
	errClaimsNoSEKey           claimsErr = "claims: no SE public key available"
	errClaimsMissing           claimsErr = "claims: claims_signature missing"
	errClaimsMissingTimestamp  claimsErr = "claims: claims_timestamp missing"
	errClaimsNonceMismatch     claimsErr = "claims: nonce mismatch"
	errClaimsTimestampMismatch claimsErr = "claims: claims_timestamp does not match challenge timestamp"
)
