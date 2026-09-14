package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/golang-jwt/jwt/v5"
)

type receiptRoundTrip func(*http.Request) (*http.Response, error)

func (f receiptRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAppAttestReceiptRenewalBoundsAndAuthentication(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalECPrivateKey(key)
	path := filepath.Join(t.TempDir(), "receipt-key.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	contextJSON, _ := json.Marshal(receiptVerificationContext{AppID: "SLDQ2GJ6TL.io.darkbloom.provider", Environment: "production"})
	old := store.AppAttestReceipt{ID: "old", KeyID: "key", Body: []byte{1, 2, 3}, Context: contextJSON, ExpiresAt: time.Now().Add(time.Hour)}
	client := &http.Client{Transport: receiptRoundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != "https://data.appattest.apple.com/v1/attestationData" {
			t.Fatal("wrong endpoint")
		}
		token, err := jwt.Parse(r.Header.Get("Authorization"), func(*jwt.Token) (any, error) { return &key.PublicKey, nil }, jwt.WithValidMethods([]string{"ES256"}), jwt.WithIssuer("SLDQ2GJ6TL"))
		if err != nil || !token.Valid || token.Header["kid"] != "TESTKEY" {
			t.Fatalf("invalid auth %v", err)
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != base64.StdEncoding.EncodeToString(old.Body) {
			t.Fatal("receipt not sent as base64 body")
		}
		return &http.Response{StatusCode: 429, Body: io.NopCloser(strings.NewReader("rate limited")), Header: make(http.Header)}, nil
	})}
	r := renewAppAttestReceipt(context.Background(), old, AppAttestShadowConfig{ReceiptKeyPath: path, ReceiptKeyID: "TESTKEY"}, client)
	if r.ParentID != old.ID || r.Outcome != "http_error" || r.HTTPStatus != 429 || string(r.ResponseBody) != "rate limited" || r.NextAt.Before(time.Now().Add(59*time.Minute)) {
		t.Fatalf("bad renewal record %+v", r)
	}
	if strings.Contains(string(r.Context), "PRIVATE KEY") || strings.Contains(string(r.Details), "Authorization") {
		t.Fatal("credentials archived")
	}
	client.Transport = receiptRoundTrip(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(strings.Repeat("a", 70*1024))), Header: make(http.Header)}, nil
	})
	r = renewAppAttestReceipt(context.Background(), old, AppAttestShadowConfig{ReceiptKeyPath: path, ReceiptKeyID: "TESTKEY"}, client)
	if r.Outcome != "response_oversized" || len(r.ResponseBody) != 64*1024 {
		t.Fatal("unbounded response")
	}
}
