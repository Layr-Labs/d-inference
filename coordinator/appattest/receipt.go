package appattest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"strconv"
	"time"

	"github.com/smallstep/pkcs7"
)

// Apple documents a separate root for receipts; the attestation root must not
// be reused here. Source: https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
//
//go:embed apple-receipt-root.cer
var receiptRoot []byte

type Receipt struct {
	Type       string    `json:"type"`
	CreatedAt  time.Time `json:"created_at"`
	NotBefore  time.Time `json:"not_before"`
	ExpiresAt  time.Time `json:"expires_at"`
	RiskMetric *uint64   `json:"risk_metric,omitempty"`
}

// ExtractReceipt preserves an independently verified receipt separately from
// the complete CBOR archive. A parse failure never discards the original proof.
func ExtractReceipt(proof []byte) []byte {
	var a attestationObject
	if len(proof) > MaxProofBytes || decoder.Unmarshal(proof, &a) != nil {
		return nil
	}
	return a.Statement.Receipt
}

func VerifyReceipt(raw, publicKey []byte, appID string, clientHash [32]byte, now time.Time) (*Receipt, error) {
	return receiptWithAppleRoot(raw, publicKey, appID, clientHash, now, true)
}

// ReceiptForRenewal validates a historical receipt ONLY as input to Apple's
// renewal endpoint. Its result is not a fresh receipt or an authorization.
// All signature, identity, key, challenge and expiration checks still apply.
func ReceiptForRenewal(raw, publicKey []byte, appID string, clientHash [32]byte, now time.Time) (*Receipt, error) {
	return receiptWithAppleRoot(raw, publicKey, appID, clientHash, now, false)
}

func receiptWithAppleRoot(raw, publicKey []byte, appID string, clientHash [32]byte, now time.Time, fresh bool) (*Receipt, error) {
	root, err := x509.ParseCertificate(receiptRoot)
	if err != nil {
		panic("invalid receipt root")
	}
	roots := x509.NewCertPool()
	roots.AddCert(root)
	return verifyReceiptWithFreshness(raw, publicKey, appID, clientHash, now, roots, fresh)
}

func verifyReceipt(raw, publicKey []byte, appID string, clientHash [32]byte, now time.Time, roots *x509.CertPool) (*Receipt, error) {
	return verifyReceiptWithFreshness(raw, publicKey, appID, clientHash, now, roots, true)
}

func verifyReceiptWithFreshness(raw, publicKey []byte, appID string, clientHash [32]byte, now time.Time, roots *x509.CertPool, fresh bool) (*Receipt, error) {
	if len(raw) == 0 || len(raw) > MaxProofBytes {
		return nil, invalid("receipt_size")
	}
	p, err := pkcs7.Parse(raw)
	if err != nil || len(p.Signers) != 1 || p.VerifyWithChainAtTime(roots, now) != nil {
		return nil, invalid("receipt_signature_or_chain")
	}
	var attrs []struct {
		Type    int
		Version int
		Value   []byte
	}
	rest, err := asn1.UnmarshalWithParams(p.Content, &attrs, "set")
	if err != nil || len(rest) != 0 || len(attrs) > 32 {
		return nil, invalid("receipt_payload")
	}
	fields := map[int][]byte{}
	for _, a := range attrs {
		if _, ok := fields[a.Type]; ok {
			return nil, invalid("receipt_duplicate_field")
		}
		fields[a.Type] = a.Value
	}
	if string(fields[2]) != appID {
		return nil, invalid("receipt_app_id")
	}
	// Apple's Mac receipts carry the attestation leaf certificate in field 3;
	// also accept the documented DER public-key representation.
	var key any
	if cert, e := x509.ParseCertificate(fields[3]); e == nil {
		key = cert.PublicKey
	} else {
		key, _ = x509.ParsePKIXPublicKey(fields[3])
	}
	ec, ok := key.(*ecdsa.PublicKey)
	if !ok || ec.Curve != elliptic.P256() || !bytes.Equal(elliptic.Marshal(ec.Curve, ec.X, ec.Y), publicKey) {
		return nil, invalid("receipt_key")
	}
	r := &Receipt{Type: string(fields[6])}
	if r.Type != "ATTEST" && r.Type != "RECEIPT" {
		return nil, invalid("receipt_type")
	}
	// The initial ATTEST receipt binds the enrollment challenge. Renewed risk
	// receipts bind the app and attested key instead: Apple's verification
	// contract does not require field 4 to repeat the enrollment hash. A real
	// macOS renewal returned that binary field with UTF-8 replacement bytes.
	// Never accept that lossy representation as a nonce binding. Authenticate
	// RECEIPT using the signature, app/key, fresh creation time and expiration.
	// https://developer.apple.com/documentation/devicecheck/assessing-fraud-risk
	if r.Type == "ATTEST" && !bytes.Equal(fields[4], clientHash[:]) {
		return nil, invalid("receipt_client_hash")
	}
	r.CreatedAt, err = time.Parse(time.RFC3339Nano, string(fields[12]))
	if err != nil || (fresh && now.Sub(r.CreatedAt) > 5*time.Minute) || r.CreatedAt.After(now.Add(30*time.Second)) {
		return nil, invalid("receipt_creation_time")
	}
	r.ExpiresAt, err = time.Parse(time.RFC3339Nano, string(fields[21]))
	if err != nil || !r.ExpiresAt.After(now) || !r.ExpiresAt.After(r.CreatedAt) {
		return nil, invalid("receipt_expired")
	}
	if len(fields[19]) > 0 {
		r.NotBefore, err = time.Parse(time.RFC3339Nano, string(fields[19]))
		if err != nil || !r.NotBefore.Before(r.ExpiresAt) {
			return nil, invalid("receipt_not_before")
		}
	}
	if r.Type == "RECEIPT" {
		n, e := strconv.ParseUint(string(fields[17]), 10, 64)
		if e != nil || r.NotBefore.IsZero() {
			return nil, invalid("receipt_risk_metric")
		}
		r.RiskMetric = &n
	}
	return r, nil
}
