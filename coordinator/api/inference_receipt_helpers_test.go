package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const receiptTestIssuer = "https://coordinator.example"

// newReceiptTestIssuer builds an issuer the way NewServer does, from a
// receipts.Config, so tests exercise the production key-ring path. retained
// lists historical public keys to publish alongside the active one.
func newReceiptTestIssuer(t *testing.T, keyID string, private ed25519.PrivateKey, retained map[string]ed25519.PublicKey) *receiptIssuer {
	t.Helper()
	cfg := receipts.Config{
		Enabled:      true,
		SigningKeyID: keyID,
		SigningKey:   base64.StdEncoding.EncodeToString(private),
	}
	if len(retained) > 0 {
		encoded := make(map[string]string, len(retained))
		for id, key := range retained {
			encoded[id] = base64.StdEncoding.EncodeToString(key)
		}
		raw, err := json.Marshal(encoded)
		if err != nil {
			t.Fatal(err)
		}
		cfg.PublicKeysJSON = string(raw)
	}
	issuer, err := newReceiptIssuer(&cfg, receiptTestIssuer)
	if err != nil || issuer == nil {
		t.Fatalf("newReceiptIssuer = (%v, %v)", issuer, err)
	}
	return issuer
}

// randomReceiptIssuer returns an issuer with a fresh active key and that key.
func randomReceiptIssuer(t *testing.T) (*receiptIssuer, ed25519.PrivateKey) {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return newReceiptTestIssuer(t, "receipt-key-test", private, nil), private
}

// newReceiptTestServer is the minimal Server the receipt handlers need. A nil
// issuer means receipts are disabled.
func newReceiptTestServer(st store.Store, issuer *receiptIssuer) *Server {
	return &Server{
		store:             st,
		inferenceReceipts: issuer,
		logger:            slog.New(slog.NewTextHandler(io.Discard, nil)),
		metrics:           NewMetrics(),
	}
}

func receiptMetricCount(s *Server, name string, labels ...MetricLabel) int64 {
	return s.metrics.Snapshot().Counters[metricKey(name, labels)]
}

func apiTestReceiptNonce() string {
	return apiTestReceiptNonceWithByte(0)
}

func apiTestReceiptNonceWithByte(value byte) string {
	nonce := make([]byte, 32)
	nonce[0] = value
	return base64.RawURLEncoding.EncodeToString(nonce)
}
