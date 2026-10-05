package appattest

import (
	"crypto/x509"
	_ "embed"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/proof"
)

// Apple documents a separate root for receipts; the attestation root must not
// be reused here. Source: https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
//
//go:embed apple-receipt-root.cer
var receiptRoot []byte

type Receipt = proof.Receipt

func ExtractReceipt(raw []byte) []byte { return proof.ExtractReceipt(raw) }

func VerifyReceipt(raw, publicKey []byte, appID string, clientHash [32]byte, now time.Time) (*Receipt, error) {
	return proof.VerifyReceipt(raw, publicKey, appID, clientHash, now, receiptTrustRoots())
}

// ReceiptForRenewal authenticates historical input, not a serving authorization.
func ReceiptForRenewal(raw, publicKey []byte, appID string, clientHash [32]byte, now time.Time) (*Receipt, error) {
	return proof.ReceiptForRenewal(raw, publicKey, appID, clientHash, now, receiptTrustRoots())
}

func receiptTrustRoots() *x509.CertPool {
	root, err := x509.ParseCertificate(receiptRoot)
	if err != nil {
		panic("invalid receipt root")
	}
	roots := x509.NewCertPool()
	roots.AddCert(root)
	return roots
}
