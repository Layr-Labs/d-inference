// Package receipts creates and verifies signed, deterministic inference receipts.
//
// CanonicalJSON's version 1 accepts exactly one top-level JSON object, rejects
// duplicate decoded keys in objects at every depth, and preserves json.Number
// lexemes. It emits compact encoding/json output with sorted map keys and
// encoding/json's default string escaping. It rejects raw inputs over 16 MiB
// and nested arrays or objects deeper than 256 levels, counting the root
// object as level 1.
package receipts

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	schemaVersion        = 1
	maxPayloadJSONBytes  = 8 * 1024
	maxIssuerBytes       = 256
	maxJobIDBytes        = 256
	maxAttemptIDBytes    = 256
	maxNonceBytes        = 256
	maxCallerRefBytes    = 512
	maxModelBytes        = 256
	maxFinishReasonBytes = 128
	maxKeyIDBytes        = 128

	// receiptDomain is deliberately fixed and versioned. Its NUL terminator
	// prevents another protocol's printable prefix from sharing this domain.
	receiptDomain = "darkbloom:inference-receipt:v1\x00"
)

// Payload is the version-1 inference result bound into a receipt.
// Field order and JSON names are part of the stable receipt encoding.
type Payload struct {
	SchemaVersion         int       `json:"schema_version"`
	Issuer                string    `json:"issuer"`
	JobID                 string    `json:"job_id"`
	WinningAttemptID      string    `json:"winning_attempt_id"`
	Nonce                 string    `json:"nonce"`
	CallerRef             string    `json:"caller_ref"`
	RequestSHA256         string    `json:"request_sha256"`
	RequestBytesSHA256    string    `json:"request_bytes_sha256"`
	ProviderRequestSHA256 string    `json:"provider_request_sha256"`
	RequestedModel        string    `json:"requested_model"`
	ResolvedModel         string    `json:"resolved_model"`
	OutputSHA256          string    `json:"output_sha256"`
	Status                string    `json:"status"`
	FinishReason          string    `json:"finish_reason"`
	CompletedAt           time.Time `json:"completed_at"`
	LookupExpiresAt       time.Time `json:"lookup_expires_at"`
}

// Envelope carries the payload, its domain-separated digest, the signing key
// identifier, and a standard-base64 Ed25519 signature.
type Envelope struct {
	Payload     Payload `json:"payload"`
	ReceiptHash string  `json:"receipt_hash"`
	KeyID       string  `json:"key_id"`
	Signature   string  `json:"signature"`
}

// Signer signs inference receipt payloads with an Ed25519 key.
type Signer struct {
	keyID      string
	privateKey ed25519.PrivateKey
}

// NewSigner creates a signer from a standard 64-byte Ed25519 private key.
func NewSigner(keyID string, key ed25519.PrivateKey) (*Signer, error) {
	if err := validateKeyID(keyID); err != nil {
		return nil, err
	}
	if len(key) != ed25519.PrivateKeySize {
		return nil, errors.New("invalid Ed25519 private key length")
	}
	derived := ed25519.NewKeyFromSeed(key[:ed25519.SeedSize])
	if subtle.ConstantTimeCompare(derived, key) != 1 {
		return nil, errors.New("invalid Ed25519 private key")
	}
	return &Signer{keyID: keyID, privateKey: append(ed25519.PrivateKey(nil), key...)}, nil
}

// NewSignerFromBytes creates a signer from either a 32-byte Ed25519 seed or a
// 64-byte Ed25519 private key.
func NewSignerFromBytes(keyID string, key []byte) (*Signer, error) {
	switch len(key) {
	case ed25519.SeedSize:
		return NewSigner(keyID, ed25519.NewKeyFromSeed(key))
	case ed25519.PrivateKeySize:
		return NewSigner(keyID, ed25519.PrivateKey(key))
	default:
		return nil, errors.New("invalid Ed25519 key material length")
	}
}

// KeyID returns the identifier associated with the signer's verification key.
// A nil or zero-value signer returns the empty string.
func (s *Signer) KeyID() string {
	if s == nil {
		return ""
	}
	return s.keyID
}

// PublicKey returns a copy of the signer's Ed25519 public key. A nil or
// zero-value signer returns nil.
func (s *Signer) PublicKey() ed25519.PublicKey {
	if s == nil || len(s.privateKey) != ed25519.PrivateKeySize {
		return nil
	}
	publicKey := s.privateKey.Public().(ed25519.PublicKey)
	return append(ed25519.PublicKey(nil), publicKey...)
}

// Sign validates payload and returns its deterministic signed envelope.
func (s *Signer) Sign(payload Payload) (Envelope, error) {
	if s == nil || len(s.privateKey) != ed25519.PrivateKeySize {
		return Envelope{}, errors.New("invalid receipt signer")
	}
	if err := validatePayload(payload); err != nil {
		return Envelope{}, err
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return Envelope{}, errors.New("could not encode receipt payload")
	}
	if len(payloadJSON) > maxPayloadJSONBytes {
		return Envelope{}, errors.New("receipt payload exceeds size limit")
	}

	digest := payloadDigest(payloadJSON)
	message := signaturePreimage(s.keyID, digest[:])
	signature := ed25519.Sign(s.privateKey, message)
	return Envelope{
		Payload:     payload,
		ReceiptHash: hex.EncodeToString(digest[:]),
		KeyID:       s.keyID,
		Signature:   base64.StdEncoding.EncodeToString(signature),
	}, nil
}

// Verify validates the receipt payload, digest, canonical encodings, and
// Ed25519 signature against publicKey.
func Verify(envelope Envelope, publicKey ed25519.PublicKey) error {
	if len(publicKey) != ed25519.PublicKeySize {
		return errors.New("invalid receipt public key")
	}
	if err := validateKeyID(envelope.KeyID); err != nil {
		return errors.New("invalid receipt key ID")
	}
	if err := validatePayload(envelope.Payload); err != nil {
		return err
	}
	payloadJSON, err := json.Marshal(envelope.Payload)
	if err != nil {
		return errors.New("could not encode receipt payload")
	}
	if len(payloadJSON) > maxPayloadJSONBytes {
		return errors.New("receipt payload exceeds size limit")
	}

	if len(envelope.ReceiptHash) != sha256.Size*2 || !isLowerHex(envelope.ReceiptHash) {
		return errors.New("invalid receipt hash encoding")
	}
	digest := payloadDigest(payloadJSON)
	expectedHash := hex.EncodeToString(digest[:])
	if subtle.ConstantTimeCompare([]byte(expectedHash), []byte(envelope.ReceiptHash)) != 1 {
		return errors.New("receipt hash mismatch")
	}

	signature, err := base64.StdEncoding.DecodeString(envelope.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || base64.StdEncoding.EncodeToString(signature) != envelope.Signature {
		return errors.New("invalid receipt signature encoding")
	}
	if !ed25519.Verify(publicKey, signaturePreimage(envelope.KeyID, digest[:]), signature) {
		return errors.New("invalid receipt signature")
	}
	return nil
}

// HashBytes returns the lowercase hexadecimal SHA-256 digest of data.
func HashBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func payloadDigest(payloadJSON []byte) [sha256.Size]byte {
	preimage := make([]byte, 0, len(receiptDomain)+len(payloadJSON))
	preimage = append(preimage, receiptDomain...)
	preimage = append(preimage, payloadJSON...)
	return sha256.Sum256(preimage)
}

func signaturePreimage(keyID string, digest []byte) []byte {
	preimage := make([]byte, len(receiptDomain)+4+len(keyID)+len(digest))
	copy(preimage, receiptDomain)
	offset := len(receiptDomain)
	binary.BigEndian.PutUint32(preimage[offset:offset+4], uint32(len(keyID)))
	offset += 4
	copy(preimage[offset:], keyID)
	offset += len(keyID)
	copy(preimage[offset:], digest)
	return preimage
}

func validatePayload(payload Payload) error {
	if payload.SchemaVersion != schemaVersion {
		return invalidPayload("schema_version")
	}
	if err := validateText("issuer", payload.Issuer, maxIssuerBytes); err != nil {
		return err
	}
	if err := validateText("job_id", payload.JobID, maxJobIDBytes); err != nil {
		return err
	}
	if err := validateText("winning_attempt_id", payload.WinningAttemptID, maxAttemptIDBytes); err != nil {
		return err
	}
	if err := validateText("nonce", payload.Nonce, maxNonceBytes); err != nil {
		return err
	}
	if err := validateText("caller_ref", payload.CallerRef, maxCallerRefBytes); err != nil {
		return err
	}
	if !validSHA256(payload.RequestSHA256) {
		return invalidPayload("request_sha256")
	}
	if !validSHA256(payload.RequestBytesSHA256) {
		return invalidPayload("request_bytes_sha256")
	}
	if !validSHA256(payload.ProviderRequestSHA256) {
		return invalidPayload("provider_request_sha256")
	}
	if err := validateText("requested_model", payload.RequestedModel, maxModelBytes); err != nil {
		return err
	}
	if err := validateText("resolved_model", payload.ResolvedModel, maxModelBytes); err != nil {
		return err
	}
	if !validSHA256(payload.OutputSHA256) {
		return invalidPayload("output_sha256")
	}
	if payload.Status != "completed" {
		return invalidPayload("status")
	}
	if err := validateText("finish_reason", payload.FinishReason, maxFinishReasonBytes); err != nil {
		return err
	}
	if !validUTCTime(payload.CompletedAt) {
		return invalidPayload("completed_at")
	}
	lookupExpiry := payload.LookupExpiresAt.Round(0)
	completedAt := payload.CompletedAt.Round(0)
	if !validUTCTime(payload.LookupExpiresAt) || !lookupExpiry.After(completedAt) {
		return invalidPayload("lookup_expires_at")
	}
	return nil
}

func validateText(field, value string, maxBytes int) error {
	if len(value) == 0 || len(value) > maxBytes || !utf8.ValidString(value) || strings.TrimSpace(value) == "" {
		return invalidPayload(field)
	}
	return nil
}

func validateKeyID(keyID string) error {
	if err := validateText("key_id", keyID, maxKeyIDBytes); err != nil {
		return errors.New("invalid receipt key ID")
	}
	return nil
}

func validSHA256(value string) bool {
	return len(value) == sha256.Size*2 && isLowerHex(value)
}

func isLowerHex(value string) bool {
	for _, char := range value {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

func validUTCTime(value time.Time) bool {
	if value.IsZero() || value.Year() < 1 || value.Year() > 9999 {
		return false
	}
	_, offset := value.Zone()
	return offset == 0
}

func invalidPayload(field string) error {
	return fmt.Errorf("invalid receipt payload: %s", field)
}
