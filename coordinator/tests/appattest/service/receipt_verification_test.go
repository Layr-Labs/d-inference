package service_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/receipt"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/fxamacker/cbor/v2"
)

// failIfCalled fails the test if renewal reaches the network.
func failIfCalled(t *testing.T) *http.Client {
	return &http.Client{Transport: receiptRoundTrip(func(*http.Request) (*http.Response, error) {
		t.Error("renewal contacted Apple")
		return nil, errors.New("unexpected request")
	})}
}

func respondWith(resp *http.Response, err error) *http.Client {
	return &http.Client{Transport: receiptRoundTrip(func(*http.Request) (*http.Response, error) { return resp, err })}
}

func appleOK(body string) *http.Response {
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}
}

func receiptContext(t *testing.T, appID, environment string) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(receipt.VerificationContext{AppID: appID, Environment: environment})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// renewalWorker never claims from storage; Renew is driven directly.
func renewalWorker(cfg receipt.Config, client *http.Client, now func() time.Time) *receipt.Worker {
	return receipt.New(cfg, receipt.Dependencies{Store: &receiptWorkerStore{}, Client: client, Now: now})
}

func TestReceiptRecordFailuresKeepHourlyRetryAndEmptyDetails(t *testing.T) {
	_, keyPath := receiptTestKey(t)
	received := time.Now().UTC()
	now := func() time.Time { return received }
	key := &store.AppAttestShadowKey{KeyID: "key", AppID: "TEST.app", Environment: "production", PublicKey: []byte{4}}
	for _, tc := range []struct {
		name string
		body []byte
		want string
	}{
		{"missing receipt", nil, "receipt_size"},
		{"not pkcs7", []byte("not a receipt"), "receipt_signature_or_chain"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			proof, err := cbor.Marshal(map[string]any{"attStmt": map[string]any{"receipt": tc.body}})
			if err != nil {
				t.Fatal(err)
			}
			r := receipt.EnrollmentRecord(key, "evidence", proof, [32]byte{}, received)
			if r.Outcome != tc.want || string(r.Details) != "{}" || !r.NextAt.Equal(received.Add(time.Hour)) || !r.ExpiresAt.IsZero() {
				t.Fatalf("enrollment record %+v", r)
			}
			// A failed refresh keeps the previous expiry for the next renewal.
			old := store.AppAttestReceipt{ID: "old", Context: receiptContext(t, "SLDQ2GJ6TL.io.darkbloom.provider", "production"), ExpiresAt: received.Add(2 * time.Hour), Body: []byte{1}}
			w := renewalWorker(receipt.Config{KeyPath: keyPath, KeyID: "TESTKEY"}, respondWith(appleOK(base64.StdEncoding.EncodeToString(tc.body)), nil), now)
			refreshed := w.Renew(context.Background(), old)
			if refreshed.Outcome != tc.want || string(refreshed.Details) != "{}" || !refreshed.NextAt.Equal(received.Add(time.Hour)) || !refreshed.ExpiresAt.Equal(old.ExpiresAt) {
				t.Fatalf("refresh record %+v", refreshed)
			}
		})
	}
}

func TestInitialReceiptBindsVerificationContextToEvidence(t *testing.T) {
	key := &store.AppAttestShadowKey{KeyID: "key", AppID: "TEST.app", Environment: "development", PublicKey: []byte{4, 5, 6}}
	hash := sha256.Sum256([]byte("client data"))
	now := time.Now()
	r := receipt.EnrollmentRecord(key, "evidence", []byte("not cbor"), hash, now)
	if r.ID == "" || r.KeyID != "key" || r.EvidenceID != "evidence" || !r.ReceivedAt.Equal(now.UTC()) || r.Body != nil {
		t.Fatalf("receipt record %+v", r)
	}
	// Without an extractable receipt the record is kept as a failed decision.
	if r.Outcome != "receipt_size" || !r.NextAt.Equal(r.ReceivedAt.Add(time.Hour)) {
		t.Fatalf("outcome %q next %v", r.Outcome, r.NextAt)
	}
	var c receipt.VerificationContext
	if err := json.Unmarshal(r.Context, &c); err != nil {
		t.Fatal(err)
	}
	if c.AppID != "TEST.app" || c.Environment != "development" || !bytes.Equal(c.PublicKey, []byte{4, 5, 6}) || c.ClientHash != hash {
		t.Fatalf("renewal context %+v", c)
	}
}

func TestReceiptRenewalRefusesBeforeContactingApple(t *testing.T) {
	_, keyPath := receiptTestKey(t)
	badKey := filepath.Join(t.TempDir(), "bad.pem")
	if err := os.WriteFile(badKey, []byte("not a key"), 0600); err != nil {
		t.Fatal(err)
	}
	missingKey := filepath.Join(t.TempDir(), "missing.pem")
	future := time.Now().Add(time.Hour)
	valid := receiptContext(t, "SLDQ2GJ6TL.io.darkbloom.provider", "production")
	for _, tc := range []struct {
		name    string
		old     store.AppAttestReceipt
		keyPath string
		want    string
	}{
		{"unreadable context", store.AppAttestReceipt{Context: json.RawMessage(`{`), ExpiresAt: future}, keyPath, "configuration_error"},
		{"expired receipt", store.AppAttestReceipt{Context: valid, ExpiresAt: time.Now().Add(-time.Minute)}, keyPath, "receipt_expired"},
		{"team id not ten characters", store.AppAttestReceipt{Context: receiptContext(t, "SHORT.app", "production"), ExpiresAt: future}, keyPath, "configuration_error"},
		{"missing key file", store.AppAttestReceipt{Context: valid, ExpiresAt: future}, missingKey, "configuration_error"},
		{"invalid key file", store.AppAttestReceipt{Context: valid, ExpiresAt: future}, badKey, "configuration_error"},
		{"unknown environment", store.AppAttestReceipt{Context: receiptContext(t, "SLDQ2GJ6TL.io.darkbloom.provider", "staging"), ExpiresAt: future}, keyPath, "configuration_error"},
		{"historical enrollment receipt", store.AppAttestReceipt{Context: valid, Body: []byte("historic"), Outcome: "receipt_creation_time"}, keyPath, "receipt_signature_or_chain"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.old.ID, tc.old.KeyID, tc.old.EvidenceID = "old", "key", "evidence"
			r := renewalWorker(receipt.Config{KeyPath: tc.keyPath, KeyID: "TESTKEY"}, failIfCalled(t), nil).Renew(context.Background(), tc.old)
			if r.Outcome != tc.want || r.ParentID != "old" || r.KeyID != "key" || r.EvidenceID != "evidence" || r.ID == "" || r.ID == "old" {
				t.Fatalf("renewal record %+v", r)
			}
		})
	}
	// Neither decision reads the signing key.
	w := renewalWorker(receipt.Config{KeyPath: missingKey, KeyID: "TESTKEY"}, failIfCalled(t), nil)
	expired := w.Renew(context.Background(), store.AppAttestReceipt{Context: valid, ExpiresAt: time.Now().Add(-time.Minute)})
	if expired.NextAt.Before(time.Now().Add(364 * 24 * time.Hour)) {
		t.Fatal("expired receipt is retried before a year")
	}
	historic := w.Renew(context.Background(), store.AppAttestReceipt{Context: valid, Body: []byte("historic"), Outcome: "receipt_creation_time"})
	if string(historic.Body) != "historic" {
		t.Fatal("recovery decision did not keep the original enrollment receipt")
	}
}

type failingBody struct{}

func (failingBody) Read([]byte) (int, error) { return 0, errors.New("connection reset") }
func (failingBody) Close() error             { return nil }

func TestReceiptRenewalRecordsAppleResponseFailures(t *testing.T) {
	_, keyPath := receiptTestKey(t)
	old := store.AppAttestReceipt{ID: "old", Context: receiptContext(t, "SLDQ2GJ6TL.io.darkbloom.provider", "production"), ExpiresAt: time.Now().Add(time.Hour), Body: []byte{1}}
	cfg := receipt.Config{KeyPath: keyPath, KeyID: "TESTKEY"}
	renew := func(client *http.Client) store.AppAttestReceipt {
		return renewalWorker(cfg, client, nil).Renew(context.Background(), old)
	}
	if r := renew(respondWith(nil, errors.New("dial failed"))); r.Outcome != "transport_error" || r.HTTPStatus != 0 {
		t.Fatalf("transport failure %+v", r)
	}
	r := renew(respondWith(&http.Response{StatusCode: 200, Body: failingBody{}, Header: make(http.Header)}, nil))
	if r.Outcome != "response_read_error" || r.HTTPStatus != 200 {
		t.Fatalf("read failure %+v", r)
	}
	if r := renew(respondWith(appleOK("%%% not base64"), nil)); r.Outcome != "malformed_receipt_response" || string(r.ResponseBody) != "%%% not base64" {
		t.Fatalf("malformed response %+v", r)
	}
	// A decodable body that is not an Apple-signed receipt is archived but
	// never becomes a verified refresh.
	body := base64.StdEncoding.EncodeToString([]byte("unsigned receipt"))
	r = renew(respondWith(appleOK(body+"\n"), nil))
	if r.Outcome != "receipt_signature_or_chain" || string(r.Body) != "unsigned receipt" || r.HTTPStatus != 200 || !r.ExpiresAt.Equal(old.ExpiresAt) {
		t.Fatalf("unsigned refresh %+v", r)
	}
}

type receiptStorageFailures struct {
	claimErr, saveErr error
}

func (s *receiptStorageFailures) ClaimAppAttestReceipt(context.Context, time.Time) (*store.AppAttestReceipt, error) {
	if s.claimErr != nil {
		return nil, s.claimErr
	}
	return &store.AppAttestReceipt{ID: "old", Context: json.RawMessage(`{`)}, nil
}

func (s *receiptStorageFailures) SaveAppAttestReceiptRefresh(context.Context, store.AppAttestReceipt) error {
	return s.saveErr
}

func TestReceiptWorkerCountsStorageFailures(t *testing.T) {
	_, keyPath := receiptTestKey(t)
	for _, tc := range []struct {
		name string
		st   *receiptStorageFailures
		want string
	}{
		{"claim fails", &receiptStorageFailures{claimErr: errors.New("down")}, "app_attest.receipt.storage_failed"},
		{"archive fails", &receiptStorageFailures{saveErr: errors.New("down")}, "app_attest.receipt.archive_failed"},
		{"archived", &receiptStorageFailures{}, "app_attest.receipt.refresh|outcome:configuration_error"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newMetricLog()
			w := receipt.New(receipt.Config{KeyPath: keyPath, KeyID: "TESTKEY"}, receipt.Dependencies{Store: tc.st, Client: failIfCalled(t), Increment: m.increment})
			ticks := make(chan time.Time, 2)
			ticks <- time.Now()
			ticks <- time.Now()
			close(ticks)
			// A closed tick source ends the worker after the queued ticks.
			w.Run(context.Background(), ticks)
			if got := m.incrCount(tc.want); got != 2 {
				t.Fatalf("%s recorded %d times", tc.want, got)
			}
		})
	}
}
