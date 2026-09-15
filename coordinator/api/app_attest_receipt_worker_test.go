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

func receiptTestKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalECPrivateKey(key)
	path := filepath.Join(t.TempDir(), "receipt-key.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	return key, path
}

func TestAppAttestReceiptRenewalBoundsAndAuthentication(t *testing.T) {
	key, path := receiptTestKey(t)
	contextJSON, _ := json.Marshal(receiptVerificationContext{AppID: "SLDQ2GJ6TL.io.darkbloom.provider", Environment: "production"})
	old := store.AppAttestReceipt{ID: "old", KeyID: "key", Body: []byte{1, 2, 3}, Context: contextJSON, ExpiresAt: time.Now().Add(time.Hour)}
	client := &http.Client{Transport: receiptRoundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != "https://data.appattest.apple.com/v1/attestationData" {
			t.Fatal("wrong endpoint")
		}
		// Apple's App Attest receipt example uses Authorization: <JWT>.
		// Parsing the entire header pins that endpoint-specific wire format.
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

type receiptWorkerStore struct {
	*store.MemoryStore
	old   store.AppAttestReceipt
	saved *store.AppAttestReceipt
	stop  context.CancelFunc
}

func (s *receiptWorkerStore) ClaimAppAttestReceipt(context.Context, time.Time) (*store.AppAttestReceipt, error) {
	return &s.old, nil
}

func (s *receiptWorkerStore) SaveAppAttestReceiptRefresh(_ context.Context, r store.AppAttestReceipt) error {
	s.saved = &r
	s.stop()
	return nil
}

func TestAppAttestReceiptWorkerRenewsWhenShadowDisabled(t *testing.T) {
	_, path := receiptTestKey(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	contextJSON, _ := json.Marshal(receiptVerificationContext{AppID: "SLDQ2GJ6TL.io.darkbloom.provider", Environment: "development"})
	st := &receiptWorkerStore{MemoryStore: store.NewMemory(store.Config{}), stop: cancel,
		old: store.AppAttestReceipt{ID: "previous", Body: []byte{1, 2, 3}, Context: contextJSON, ExpiresAt: time.Now().Add(time.Hour)}}
	s := &Server{store: st, appAttestShadow: AppAttestShadowConfig{Enabled: false, ReceiptKeyID: "TESTKEY", ReceiptKeyPath: path}}
	worker := s.newAppAttestReceiptWorker()
	if worker == nil {
		t.Fatal("disabling new shadow exchanges disabled renewal of existing receipts")
	}
	requests := 0
	client := &http.Client{Transport: receiptRoundTrip(func(r *http.Request) (*http.Response, error) {
		requests++
		if r.URL.Host != "data-development.appattest.apple.com" {
			t.Error("worker lost original receipt environment")
		}
		return &http.Response{StatusCode: http.StatusNotModified, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header)}, nil
	})}
	ticks := make(chan time.Time, 1)
	ticks <- time.Now()
	worker.run(ctx, ticks, client)
	if requests != 1 || st.saved == nil || st.saved.ParentID != st.old.ID || st.saved.Outcome != "not_modified" {
		t.Fatalf("existing receipt was not renewed and archived: requests=%d record=%+v", requests, st.saved)
	}
	for _, cfg := range []AppAttestShadowConfig{{ReceiptKeyPath: path}, {ReceiptKeyID: "TESTKEY"}} {
		s.appAttestShadow = cfg
		if s.newAppAttestReceiptWorker() != nil {
			t.Fatal("partial credentials must not start receipt renewal")
		}
	}
}
