package protocol

// AttestationChallengeMessage is sent by the coordinator to challenge a provider
// to prove it still holds its private key.
type AttestationChallengeMessage struct {
	Type      string `json:"type"`
	Nonce     string `json:"nonce"`     // base64-encoded random 32-byte nonce
	Timestamp string `json:"timestamp"` // ISO 8601 timestamp
}

// CodeAttestationResumeChallenge proves possession of the cached registration
// X25519 private key over the live WebSocket without spending another APNs push.
type CodeAttestationResumeChallenge struct {
	Type          string           `json:"type"`
	CodeChallenge EncryptedPayload `json:"code_challenge"`
}

// AttestationResponseMessage is sent by the provider in response to an
// attestation challenge. The Signature field covers nonce + timestamp only;
// it proves the responder still holds the SE key. Status fields below
// (SIPEnabled, BinaryHash, etc.) are NOT covered by Signature and would be
// trivially forgeable if used in isolation.
//
// StatusSignature (added in v0.3.11) covers a canonical JSON of nonce +
// timestamp + all status fields, sealing them against tampering. New
// providers send both signatures; old providers send only Signature, in
// which case the status fields are treated as advisory (not a basis for
// trust upgrades).
type AttestationResponseMessage struct {
	Type            string `json:"type"`
	Nonce           string `json:"nonce"`                      // echoed back from the challenge
	Signature       string `json:"signature"`                  // base64-encoded signature of nonce+timestamp
	StatusSignature string `json:"status_signature,omitempty"` // base64-encoded signature of canonical status JSON (see attestation.BuildStatusCanonical)
	PublicKey       string `json:"public_key"`                 // base64-encoded public key
	// HypervisorActive — legacy fleet compat only: old providers (< v0.6.31)
	// sign hypervisor_active into the canonical status (see
	// attestation.BuildStatusCanonical), so this field must keep decoding for
	// their StatusSignature to verify. The concept is retired — new providers
	// omit it. Remove once the fleet floor passes v0.6.31.
	HypervisorActive  *bool  `json:"hypervisor_active,omitempty"`
	RDMADisabled      *bool  `json:"rdma_disabled,omitempty"`       // fresh RDMA status (true = disabled, false = enabled)
	SIPEnabled        *bool  `json:"sip_enabled,omitempty"`         // fresh SIP status at challenge time
	SecureBootEnabled *bool  `json:"secure_boot_enabled,omitempty"` // fresh Secure Boot status
	BinaryHash        string `json:"binary_hash,omitempty"`         // fresh SHA-256 of provider binary
	ActiveModelHash   string `json:"active_model_hash,omitempty"`   // SHA-256 weight fingerprint of loaded model

	// Runtime integrity hashes — fresh values reported at challenge time.
	PythonHash     string            `json:"python_hash,omitempty"`     // SHA-256 of Python runtime
	RuntimeHash    string            `json:"runtime_hash,omitempty"`    // SHA-256 of inference runtime (MLX-Swift)
	TemplateHashes map[string]string `json:"template_hashes,omitempty"` // template_name -> SHA-256 hash
	ModelHashes    map[string]string `json:"model_hashes,omitempty"`    // model_id -> SHA-256 weight hash (all active models)
}

// CodeAttestationResponseMessage is the provider's reply to the APNs-delivered
// code-identity challenge. The coordinator pushed E_K(nonce) (a nonce encrypted
// to the provider's registered X25519 key K) over APNs; only our genuine,
// Apple-provisioned binary can receive that push, and only the genuine process
// can decrypt it with K. The provider returns:
//   - Nonce:     the DECRYPTED nonce (proves it could decrypt E_K(nonce) ⟹ holds K)
//   - Signature: Sign_SE(nonce) from the persistent Secure-Enclave P-256 key
//     (proves it holds the SE identity bound to K at registration)
//
// Note: K is X25519 (decrypt-only); the signature comes from the separate SE key.
// The coordinator verifies Nonce == the nonce it pushed, and Signature against
// the SE public key bound to this connection at registration — never a key
// supplied in this message. This binds the Apple-gated push proof onto THIS
// WebSocket connection.
type CodeAttestationResponseMessage struct {
	Type      string `json:"type"`
	Nonce     string `json:"nonce"`     // decrypted challenge nonce, base64 (must equal the pushed nonce)
	Signature string `json:"signature"` // base64 SE-key (P-256) signature over the nonce bytes
}
