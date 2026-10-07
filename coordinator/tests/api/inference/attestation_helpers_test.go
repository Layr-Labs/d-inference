package inference_test

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"fmt"
	"math/big"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type ecdsaSigHelper struct {
	R, S *big.Int
}

var testAttestationChallengeKeys sync.Map

func testChallengeSignature(nonce, timestamp, encryptionKey string) string {
	if rawKey, ok := testAttestationChallengeKeys.Load(encryptionKey); ok {
		if privKey, ok := rawKey.(*ecdsa.PrivateKey); ok && privKey != nil {
			hash := sha256.Sum256([]byte(nonce + timestamp))
			r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
			if err == nil {
				if sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s}); err == nil {
					return base64.StdEncoding.EncodeToString(sigDER)
				}
			}
		}
	}
	return "dGVzdHNpZ25hdHVyZQ=="
}

// testResponseStatusSignature returns the status_signature a current provider
// sends with resp for the challenge (nonce, timestamp): the canonical status
// of resp's own fields, signed by the key registered for encryptionKey. It
// returns "" when no signer is registered (an unattested test provider).
func testResponseStatusSignature(nonce, timestamp, encryptionKey string, resp *protocol.AttestationResponseMessage) string {
	if _, ok := testAttestationChallengeKeys.Load(encryptionKey); !ok {
		return ""
	}
	sig, _ := signTestStatus(testResponseStatusInput(nonce, timestamp, resp), encryptionKey)
	return sig
}

// testResponseStatusInput is the canonical status input for resp's fields.
func testResponseStatusInput(nonce, timestamp string, resp *protocol.AttestationResponseMessage) attestation.StatusCanonicalInput {
	return attestation.StatusCanonicalInput{
		Nonce:             nonce,
		Timestamp:         timestamp,
		RDMADisabled:      resp.RDMADisabled,
		SIPEnabled:        resp.SIPEnabled,
		SecureBootEnabled: resp.SecureBootEnabled,
		BinaryHash:        resp.BinaryHash,
		ActiveModelHash:   resp.ActiveModelHash,
		TemplateHashes:    resp.TemplateHashes,
		ModelHashes:       resp.ModelHashes,
	}
}

func signTestStatus(in attestation.StatusCanonicalInput, encryptionKey string) (string, error) {
	rawKey, _ := testAttestationChallengeKeys.Load(encryptionKey)
	privKey, ok := rawKey.(*ecdsa.PrivateKey)
	if !ok || privKey == nil {
		return "", fmt.Errorf("invalid challenge signer for %q", encryptionKey)
	}
	canonical, err := attestation.BuildStatusCanonical(in)
	if err != nil {
		return "", fmt.Errorf("BuildStatusCanonical: %w", err)
	}
	hash := sha256.Sum256(canonical)
	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
	if err != nil {
		return "", fmt.Errorf("sign status: %w", err)
	}
	sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s})
	if err != nil {
		return "", fmt.Errorf("marshal status sig: %w", err)
	}
	return base64.StdEncoding.EncodeToString(sigDER), nil
}
