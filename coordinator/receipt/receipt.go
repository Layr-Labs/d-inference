// Package receipt implements inference receipts.
//
// A receipt is a canonical, content-addressed record of one inference:
// which model (by aggregate weight hash) ran which request (by digest of the
// exact decrypted request bytes, which bind every sampling parameter) and
// produced which response (by digest of the full response text). Its receipt hash is the SHA-256 of its canonical
// JSON bytes, and the provider's Secure Enclave signs that hash through the
// existing response attestation channel (`se_signature` over
// `response_hash`) unchanged: for a v2 provider, `response_hash` IS the
// receipt hash of the `receipt` field.
//
// The receipt carries digests only — never prompt or response plaintext —
// so it is publicly shareable without weakening the privacy model.
package receipt

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Version is the receipt schema version this package produces and accepts.
const Version = 2

// Receipt is the canonical v2 inference receipt. Field names and their
// alphabetical order define the canonical JSON form; the Swift provider
// mirrors this exactly (InferenceReceipt.swift).
type Receipt struct {
	CompletionTokens int    `json:"completion_tokens"`
	ModelID          string `json:"model_id"`
	ModelWeightHash  string `json:"model_weight_hash"` // lowercase hex aggregate SHA-256; "" when unhashed
	PromptTokens     int    `json:"prompt_tokens"`
	RequestID        string `json:"request_id"`
	RequestSHA256    string `json:"request_sha256"`  // SHA-256 of the exact decrypted request body bytes
	ResponseSHA256   string `json:"response_sha256"` // SHA-256 of the full response text (UTF-8)
	V                int    `json:"v"`
}

// Canonical returns the canonical JSON encoding of the receipt: single line,
// keys in alphabetical order, minimal escaping, no HTML or slash escaping.
// Both the receipt hash and the Secure Enclave signature cover these bytes'
// SHA-256, so this encoding must stay byte-identical to the Swift encoder.
func (r Receipt) Canonical() []byte {
	var b strings.Builder
	b.WriteByte('{')
	writeIntField(&b, "completion_tokens", r.CompletionTokens, false)
	writeStringField(&b, "model_id", r.ModelID)
	writeStringField(&b, "model_weight_hash", r.ModelWeightHash)
	writeIntField(&b, "prompt_tokens", r.PromptTokens, true)
	writeStringField(&b, "request_id", r.RequestID)
	writeStringField(&b, "request_sha256", r.RequestSHA256)
	writeStringField(&b, "response_sha256", r.ResponseSHA256)
	writeIntField(&b, "v", r.V, true)
	b.WriteByte('}')
	return []byte(b.String())
}

// Address returns the receipt hash: the lowercase hex SHA-256 of the canonical
// bytes. For a v2 provider this is the value carried in `response_hash`.
func (r Receipt) Address() string {
	sum := sha256.Sum256(r.Canonical())
	return hex.EncodeToString(sum[:])
}

// AddressOf returns the receipt hash of raw receipt bytes as received on the
// wire, without re-encoding. Verifiers should prefer this over
// Receipt.Address for wire bytes, exactly as attestation verification uses
// the original signed bytes.
func AddressOf(receiptJSON []byte) string {
	sum := sha256.Sum256(receiptJSON)
	return hex.EncodeToString(sum[:])
}

// Parse decodes receipt JSON strictly: unknown fields are rejected and the
// bytes must already be in canonical form (re-encoding must reproduce the
// input byte-for-byte). The canonical-form requirement makes the address
// unambiguous — there is exactly one byte string for a given receipt.
func Parse(receiptJSON []byte) (Receipt, error) {
	var r Receipt
	dec := json.NewDecoder(strings.NewReader(string(receiptJSON)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return Receipt{}, fmt.Errorf("invalid receipt JSON: %w", err)
	}
	if dec.More() {
		return Receipt{}, fmt.Errorf("trailing data after receipt")
	}
	if r.V != Version {
		return Receipt{}, fmt.Errorf("unsupported receipt version %d", r.V)
	}
	if string(r.Canonical()) != string(receiptJSON) {
		return Receipt{}, fmt.Errorf("receipt is not in canonical form")
	}
	if !validHex256(r.RequestSHA256) {
		return Receipt{}, fmt.Errorf("request_sha256 is not lowercase hex-256")
	}
	if !validHex256(r.ResponseSHA256) {
		return Receipt{}, fmt.Errorf("response_sha256 is not lowercase hex-256")
	}
	if r.ModelWeightHash != "" && !validHex256(r.ModelWeightHash) {
		return Receipt{}, fmt.Errorf("model_weight_hash is not lowercase hex-256")
	}
	if r.RequestID == "" || r.ModelID == "" {
		return Receipt{}, fmt.Errorf("request_id and model_id are required")
	}
	if r.CompletionTokens < 0 || r.PromptTokens < 0 {
		return Receipt{}, fmt.Errorf("token counts must be non-negative")
	}
	return r, nil
}

// VerifySignature checks the provider's Secure Enclave signature over the
// receipt hash. The signing contract matches the existing v1 response
// attestation exactly: DER-encoded ECDSA P-256 over SHA-256 of the UTF-8
// bytes of the lowercase hex address. publicKeyB64 is the provider's
// attested SE public key (base64 raw uncompressed P-256 point).
func VerifySignature(address, signatureB64, publicKeyB64 string) error {
	pubBytes, err := base64.StdEncoding.DecodeString(publicKeyB64)
	if err != nil {
		return fmt.Errorf("invalid public key base64: %w", err)
	}
	pub, err := attestation.ParseP256PublicKey(pubBytes)
	if err != nil {
		return fmt.Errorf("invalid public key: %w", err)
	}
	sigBytes, err := base64.StdEncoding.DecodeString(signatureB64)
	if err != nil {
		return fmt.Errorf("invalid signature base64: %w", err)
	}
	var sig struct{ R, S *big.Int }
	if _, err := asn1.Unmarshal(sigBytes, &sig); err != nil {
		return fmt.Errorf("invalid DER signature: %w", err)
	}
	digest := sha256.Sum256([]byte(address))
	if !ecdsa.Verify(pub, digest[:], sig.R, sig.S) {
		return fmt.Errorf("signature verification failed")
	}
	return nil
}

// SHA256Hex returns the lowercase hex SHA-256 of data — the digest form used
// for request_sha256 (over exact request body bytes) and response_sha256
// (over the full response text UTF-8 bytes).
func SHA256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// Checks is the coordinator-side verification verdict for one receipt.
// Every binding is independent and tri-state: a *Checked field says whether
// the coordinator had the input to run that check at completion time (e.g.
// sealed-sender mode hides the plaintext body; an unattested provider has
// no known SE key).
type Checks struct {
	// AddressMatch: SHA-256 of the wire receipt bytes equals response_hash.
	AddressMatch bool `json:"address_match"`
	// RequestDigestMatch: receipt's request_sha256 equals the digest of the
	// plaintext body this coordinator sealed for the provider. False also
	// when the coordinator never saw plaintext (sealed-sender mode); see
	// RequestDigestChecked.
	RequestDigestMatch   bool `json:"request_digest_match"`
	RequestDigestChecked bool `json:"request_digest_checked"`
	// ModelWeightHashMatch: receipt's model_weight_hash equals the registry
	// catalog's aggregate weight hash for the model. Checked only when both
	// sides have a hash.
	ModelWeightHashMatch   bool `json:"model_weight_hash_match"`
	ModelWeightHashChecked bool `json:"model_weight_hash_checked"`
	// SignatureValid: SE signature over the address verifies against the
	// provider's attested public key. Checked only when the key is known.
	SignatureValid   bool `json:"signature_valid"`
	SignatureChecked bool `json:"signature_checked"`
}

// OK reports whether every check that could be performed passed.
func (c Checks) OK() bool {
	if !c.AddressMatch {
		return false
	}
	if c.RequestDigestChecked && !c.RequestDigestMatch {
		return false
	}
	if c.ModelWeightHashChecked && !c.ModelWeightHashMatch {
		return false
	}
	if c.SignatureChecked && !c.SignatureValid {
		return false
	}
	return true
}

// VerifyInput carries everything the coordinator knows at inference_complete
// time that a receipt can be checked against. Empty fields skip their check.
type VerifyInput struct {
	ReceiptJSON       []byte // wire bytes of the receipt field
	ResponseHash      string // wire response_hash (expected receipt hash)
	SESignatureB64    string // wire se_signature
	SEPublicKeyB64    string // provider's attested SE public key, if known
	DispatchedSHA256  string // digest of the plaintext body the coordinator sealed, if it saw plaintext
	CatalogWeightHash string // registry aggregate weight hash for the model, if recorded
}

// Verify parses the receipt and runs every check the input allows.
// It returns the parsed receipt alongside the verdict; the receipt is valid
// to read even when some checks fail (the verdict says which).
func Verify(in VerifyInput) (Receipt, Checks, error) {
	var checks Checks
	r, err := Parse(in.ReceiptJSON)
	if err != nil {
		return Receipt{}, checks, err
	}
	addr := AddressOf(in.ReceiptJSON)
	checks.AddressMatch = addr == strings.ToLower(strings.TrimSpace(in.ResponseHash))
	if in.DispatchedSHA256 != "" {
		checks.RequestDigestChecked = true
		checks.RequestDigestMatch = r.RequestSHA256 == in.DispatchedSHA256
	}
	if in.CatalogWeightHash != "" && r.ModelWeightHash != "" {
		checks.ModelWeightHashChecked = true
		checks.ModelWeightHashMatch = strings.EqualFold(r.ModelWeightHash, strings.TrimSpace(in.CatalogWeightHash))
	}
	if in.SEPublicKeyB64 != "" && in.SESignatureB64 != "" {
		checks.SignatureChecked = true
		checks.SignatureValid = VerifySignature(addr, in.SESignatureB64, in.SEPublicKeyB64) == nil
	}
	return r, checks, nil
}

func validHex256(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func writeIntField(b *strings.Builder, key string, v int, comma bool) {
	if comma {
		b.WriteByte(',')
	}
	fmt.Fprintf(b, "%q:%d", key, v)
}

func writeStringField(b *strings.Builder, key, v string) {
	b.WriteByte(',')
	b.WriteString(fmt.Sprintf("%q:", key))
	b.WriteString(encodeJSONString(v))
}

// encodeJSONString escapes exactly what JSON requires and nothing more:
// backslash, double quote, and control characters (U+0000..U+001F). No HTML
// escaping, no slash escaping. The Swift encoder mirrors this table.
func encodeJSONString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, ch := range s {
		switch ch {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if ch < 0x20 {
				fmt.Fprintf(&b, `\u%04x`, ch)
			} else {
				b.WriteRune(ch)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
