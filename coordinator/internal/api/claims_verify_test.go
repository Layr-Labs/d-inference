package api

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"math/big"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
)

// signClaims signs the canonical bytes with a fresh P-256 key and returns
// (base64 raw pubkey 64 bytes, base64 DER signature).
func signClaims(t *testing.T, canonical []byte) (string, string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(canonical)
	r, s, err := ecdsa.Sign(rand.Reader, priv, h[:])
	if err != nil {
		t.Fatal(err)
	}
	der, err := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	if err != nil {
		t.Fatal(err)
	}
	xBytes := priv.PublicKey.X.Bytes()
	yBytes := priv.PublicKey.Y.Bytes()
	pad := func(b []byte) []byte {
		out := make([]byte, 32)
		copy(out[32-len(b):], b)
		return out
	}
	raw := append(pad(xBytes), pad(yBytes)...)
	return base64.StdEncoding.EncodeToString(raw), base64.StdEncoding.EncodeToString(der)
}

func TestVerifyRegisterClaimsRejectsTamperedField(t *testing.T) {
	timestamp := time.Now().UTC().Format(time.RFC3339)
	regMsg := &protocol.RegisterMessage{
		Type:            protocol.TypeRegister,
		Backend:         "vllm_mlx",
		Version:         "0.4.0",
		PublicKey:       "abc",
		WalletAddress:   "0xhonest",
		PythonHash:      "ph",
		RuntimeHash:     "rh",
		ClaimsTimestamp: timestamp,
		TemplateHashes:  map[string]string{},
		ModelHashes:     map[string]string{},
	}

	canonical := protocol.CanonicalRegisterJSON(protocol.RegisterClaims{
		Timestamp:      timestamp,
		Backend:        regMsg.Backend,
		Version:        regMsg.Version,
		PublicKey:      regMsg.PublicKey,
		WalletAddress:  regMsg.WalletAddress,
		PythonHash:     regMsg.PythonHash,
		RuntimeHash:    regMsg.RuntimeHash,
		TemplateHashes: regMsg.TemplateHashes,
		ModelHashes:    regMsg.ModelHashes,
	})
	pub, sig := signClaims(t, canonical)
	regMsg.ClaimsSignature = sig

	if err := verifyRegisterClaims(pub, regMsg); err != nil {
		t.Fatalf("expected verification success, got %v", err)
	}

	// Now tamper with wallet_address; the signature is over the original
	// bytes so verification must fail. This is the F12 / F2 protection:
	// a one-line provider patch can no longer redirect payouts.
	regMsg.WalletAddress = "0xATTACKER"
	if err := verifyRegisterClaims(pub, regMsg); err == nil {
		t.Fatal("expected verification to fail after wallet_address tampering, got nil")
	}
}

// A claims envelope older than MaxClaimsAge is rejected even if the
// signature is otherwise valid. This prevents replay of a captured
// envelope long after the device has been retired or compromised.
func TestVerifyRegisterClaimsRejectsStaleTimestamp(t *testing.T) {
	timestamp := time.Now().Add(-72 * time.Hour).UTC().Format(time.RFC3339)
	regMsg := &protocol.RegisterMessage{
		Type:            protocol.TypeRegister,
		Backend:         "vllm_mlx",
		Version:         "0.4.0",
		PublicKey:       "abc",
		ClaimsTimestamp: timestamp,
		TemplateHashes:  map[string]string{},
		ModelHashes:     map[string]string{},
	}
	canonical := protocol.CanonicalRegisterJSON(protocol.RegisterClaims{
		Timestamp:      timestamp,
		Backend:        regMsg.Backend,
		Version:        regMsg.Version,
		PublicKey:      regMsg.PublicKey,
		TemplateHashes: regMsg.TemplateHashes,
		ModelHashes:    regMsg.ModelHashes,
	})
	pub, sig := signClaims(t, canonical)
	regMsg.ClaimsSignature = sig
	if err := verifyRegisterClaims(pub, regMsg); err != errClaimsStale {
		t.Fatalf("expected errClaimsStale, got %v", err)
	}
}

// A claims envelope timestamped > 5min in the future is rejected (clock skew
// safeguard) so a provider can't game the freshness window forward.
func TestVerifyRegisterClaimsRejectsFutureTimestamp(t *testing.T) {
	timestamp := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	regMsg := &protocol.RegisterMessage{
		Type:            protocol.TypeRegister,
		Backend:         "vllm_mlx",
		Version:         "0.4.0",
		PublicKey:       "abc",
		ClaimsTimestamp: timestamp,
		TemplateHashes:  map[string]string{},
		ModelHashes:     map[string]string{},
	}
	canonical := protocol.CanonicalRegisterJSON(protocol.RegisterClaims{
		Timestamp:      timestamp,
		Backend:        regMsg.Backend,
		Version:        regMsg.Version,
		PublicKey:      regMsg.PublicKey,
		TemplateHashes: regMsg.TemplateHashes,
		ModelHashes:    regMsg.ModelHashes,
	})
	pub, sig := signClaims(t, canonical)
	regMsg.ClaimsSignature = sig
	if err := verifyRegisterClaims(pub, regMsg); err != errClaimsFutureTimestamp {
		t.Fatalf("expected errClaimsFutureTimestamp, got %v", err)
	}
}

func TestVerifyChallengeClaimsRejectsReplay(t *testing.T) {
	c := protocol.ChallengeClaims{
		Nonce:             "freshnonce",
		Timestamp:         "2026-04-01T12:00:00Z",
		BinaryHash:        "bh",
		ActiveModelHash:   "amh",
		PythonHash:        "ph",
		RuntimeHash:       "rh",
		TemplateHashes:    map[string]string{},
		ModelHashes:       map[string]string{},
		SIPEnabled:        true,
		SecureBootEnabled: true,
		RDMADisabled:      true,
		HypervisorActive:  false,
	}
	pub, sig := signClaims(t, protocol.CanonicalChallengeJSON(c))

	resp := &protocol.AttestationResponseMessage{
		Nonce:             c.Nonce,
		ClaimsTimestamp:   c.Timestamp,
		ClaimsSignature:   sig,
		BinaryHash:        c.BinaryHash,
		ActiveModelHash:   c.ActiveModelHash,
		PythonHash:        c.PythonHash,
		RuntimeHash:       c.RuntimeHash,
		TemplateHashes:    c.TemplateHashes,
		ModelHashes:       c.ModelHashes,
		SIPEnabled:        boolPtr(true),
		SecureBootEnabled: boolPtr(true),
		RDMADisabled:      boolPtr(true),
		HypervisorActive:  boolPtr(false),
	}

	// Replay against a different nonce must fail.
	if err := verifyChallengeClaims(pub, "different_nonce", c.Timestamp, resp); err != errClaimsNonceMismatch {
		t.Fatalf("expected nonce mismatch, got %v", err)
	}
	// Replay against a different timestamp must fail.
	if err := verifyChallengeClaims(pub, c.Nonce, "different_timestamp", resp); err != errClaimsTimestampMismatch {
		t.Fatalf("expected timestamp mismatch, got %v", err)
	}
	// Correct nonce + timestamp succeeds.
	if err := verifyChallengeClaims(pub, c.Nonce, c.Timestamp, resp); err != nil {
		t.Fatalf("expected success, got %v", err)
	}

	// Tampering with binary_hash after the fact must fail.
	resp.BinaryHash = "TAMPERED"
	if err := verifyChallengeClaims(pub, c.Nonce, c.Timestamp, resp); err == nil {
		t.Fatal("expected verification to fail after binary_hash tampering")
	}
}

func TestVerifyChallengeClaimsRejectsTamperedSIPFlag(t *testing.T) {
	c := protocol.ChallengeClaims{
		Nonce:             "n",
		Timestamp:         "t",
		SIPEnabled:        false, // signed value
		SecureBootEnabled: true,
		RDMADisabled:      true,
		HypervisorActive:  false,
		TemplateHashes:    map[string]string{},
		ModelHashes:       map[string]string{},
	}
	pub, sig := signClaims(t, protocol.CanonicalChallengeJSON(c))
	resp := &protocol.AttestationResponseMessage{
		Nonce:             c.Nonce,
		ClaimsTimestamp:   c.Timestamp,
		ClaimsSignature:   sig,
		SIPEnabled:        boolPtr(true), // attacker flips false→true
		SecureBootEnabled: boolPtr(true),
		RDMADisabled:      boolPtr(true),
		HypervisorActive:  boolPtr(false),
		TemplateHashes:    map[string]string{},
		ModelHashes:       map[string]string{},
	}
	if err := verifyChallengeClaims(pub, c.Nonce, c.Timestamp, resp); err == nil {
		t.Fatal("expected verification failure when sip_enabled is flipped")
	}
}

func boolPtr(b bool) *bool { return &b }
