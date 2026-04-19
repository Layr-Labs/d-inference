// Package protocol — signed integrity claims envelope.
//
// The provider used to send Register / AttestationResponse messages with
// dozens of integrity-bearing fields (binary_hash, runtime_hash, model
// weight hashes, wallet address, …) but the SE signature only covered
// `nonce || timestamp`. Anything else could be lied about with a one-line
// patch to the provider binary.
//
// SignedClaims is the canonical envelope that captures every such field. The
// provider serializes it as deterministic JSON (sorted keys, no whitespace)
// and SE-signs it. The coordinator recomputes the same canonical JSON from
// the fields it received, verifies the signature against the provider's SE
// public key, and only trusts the values that came out of the signed
// envelope.
//
// Float fields (TPS) are represented as integer milli-units to avoid
// cross-language float formatting differences.

package protocol

import (
	"encoding/json"
	"sort"
	"strings"
)

// RegisterClaims captures every integrity-bearing field of a Register message.
// Provider builds CanonicalRegisterJSON(...) from these values and SE-signs
// the bytes; coordinator does the same and verifies.
type RegisterClaims struct {
	Timestamp       string
	Backend         string
	Version         string
	PublicKey       string
	WalletAddress   string
	AuthToken       string
	PythonHash      string
	RuntimeHash     string
	GrpcBinaryHash  string
	ImageBridgeHash string
	TemplateHashes  map[string]string
	ModelHashes     map[string]string
	PrefillTPSMilli uint64
	DecodeTPSMilli  uint64
}

// ChallengeClaims captures every integrity-bearing field of an
// AttestationResponse message. Bound to the coordinator-issued challenge
// nonce + timestamp so this envelope cannot be replayed.
type ChallengeClaims struct {
	Nonce             string
	Timestamp         string
	BinaryHash        string
	ActiveModelHash   string
	PythonHash        string
	RuntimeHash       string
	GrpcBinaryHash    string
	ImageBridgeHash   string
	TemplateHashes    map[string]string
	ModelHashes       map[string]string
	SIPEnabled        bool
	SecureBootEnabled bool
	RDMADisabled      bool
	HypervisorActive  bool
}

// CanonicalRegisterJSON serializes RegisterClaims with alphabetical key order
// and no whitespace, matching the provider's canonical_register_json output.
func CanonicalRegisterJSON(c RegisterClaims) []byte {
	m := map[string]any{
		"auth_token":        c.AuthToken,
		"backend":           c.Backend,
		"decode_tps_milli":  c.DecodeTPSMilli,
		"grpc_binary_hash":  c.GrpcBinaryHash,
		"image_bridge_hash": c.ImageBridgeHash,
		"model_hashes":      sortedMap(c.ModelHashes),
		"prefill_tps_milli": c.PrefillTPSMilli,
		"public_key":        c.PublicKey,
		"python_hash":       c.PythonHash,
		"runtime_hash":      c.RuntimeHash,
		"template_hashes":   sortedMap(c.TemplateHashes),
		"timestamp":         c.Timestamp,
		"version":           c.Version,
		"wallet_address":    c.WalletAddress,
	}
	return canonicalEncode(m)
}

// CanonicalChallengeJSON serializes ChallengeClaims with alphabetical key
// order and no whitespace, matching the provider's canonical_challenge_json.
func CanonicalChallengeJSON(c ChallengeClaims) []byte {
	m := map[string]any{
		"active_model_hash":   c.ActiveModelHash,
		"binary_hash":         c.BinaryHash,
		"grpc_binary_hash":    c.GrpcBinaryHash,
		"hypervisor_active":   c.HypervisorActive,
		"image_bridge_hash":   c.ImageBridgeHash,
		"model_hashes":        sortedMap(c.ModelHashes),
		"nonce":               c.Nonce,
		"python_hash":         c.PythonHash,
		"rdma_disabled":       c.RDMADisabled,
		"runtime_hash":        c.RuntimeHash,
		"secure_boot_enabled": c.SecureBootEnabled,
		"sip_enabled":         c.SIPEnabled,
		"template_hashes":     sortedMap(c.TemplateHashes),
		"timestamp":           c.Timestamp,
	}
	return canonicalEncode(m)
}

// sortedMap returns a map[string]any with the same keys/values; encoding/json
// emits map keys in sorted order for any map[string]X (Go ≥1.12), so this is
// sufficient to produce alphabetically-sorted nested objects matching the
// provider's BTreeMap output. We always emit an object (never null) so the
// canonical bytes match between Rust (`BTreeMap` always object) and Go.
func sortedMap(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// canonicalEncode produces a deterministic JSON encoding: alphabetical top-
// level keys (encoding/json sorts map keys), no HTML escaping, no trailing
// newline. We use json.Marshal on a map[string]any because Go's encoder
// outputs map[string]X keys in sorted order, matching the Rust BTreeMap.
func canonicalEncode(m map[string]any) []byte {
	// Use a custom encoder to disable HTML escaping. json.Marshal escapes
	// '<', '>', '&' which Rust's serde_json does not, leading to a hash
	// mismatch on hashes that happen to contain those byte sequences (rare
	// for hex hashes but possible for the auth_token field).
	var sb strings.Builder
	enc := json.NewEncoder(&sb)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(m); err != nil {
		return nil
	}
	out := sb.String()
	// json.Encoder appends a newline; strip it.
	out = strings.TrimRight(out, "\n")
	return []byte(out)
}

// keysSorted returns the alphabetically-sorted keys of m. Useful in tests.
func keysSorted(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
