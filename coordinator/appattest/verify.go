// Package appattest verifies evidence with pinned Apple trust anchors.
package appattest

import (
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/hex"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/proof"
)

// Root downloaded from https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem.
// No environment/configuration override is allowed.
//
//go:embed apple-root.pem
var appleRoot []byte

const MaxProofBytes = proof.MaxProofBytes
const VerifierVersion = proof.VerifierVersion

type Policy = proof.Policy
type Key = proof.Key

type Verifier struct {
	core *proof.CoreVerifier
}

func RootSHA256() string { hash := sha256.Sum256(appleRoot); return hex.EncodeToString(hash[:]) }

func New(policy Policy) *Verifier {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(appleRoot) {
		panic("invalid embedded App Attest root")
	}
	return &Verifier{core: proof.New(proof.Config{Policy: policy, Roots: roots, Now: time.Now})}
}

func (v *Verifier) Attestation(raw []byte, keyID string, clientHash [32]byte) (*Key, error) {
	return v.core.Attestation(raw, keyID, clientHash)
}

func (v *Verifier) Assertion(raw, publicKey []byte, clientHash [32]byte, previous uint32) (uint32, *Key, error) {
	return v.core.Assertion(raw, publicKey, clientHash, previous)
}
