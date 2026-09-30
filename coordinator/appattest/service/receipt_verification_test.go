package service

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

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestReceiptRecordFailuresKeepHourlyRetryAndEmptyDetails(t *testing.T) {
	received := time.Now().UTC()
	for _, tc := range []struct {
		name string
		body []byte
		want string
	}{
		{"missing receipt", nil, "receipt_size"},
		{"not pkcs7", []byte("not a receipt"), "receipt_signature_or_chain"},
	} {
		for _, initial := range []bool{false, true} {
			r := &store.AppAttestReceipt{Body: tc.body, ReceivedAt: received}
			verifyReceiptRecordMode(r, receiptVerificationContext{AppID: "TEST.app", PublicKey: []byte{4}}, initial)
			if r.Outcome != tc.want || string(r.Details) != "{}" || !r.NextAt.Equal(received.Add(time.Hour)) || !r.ExpiresAt.IsZero() {
				t.Fatalf("%s initial=%v: %+v", tc.name, initial, r)
			}
		}
	}
	// The wrappers select the refresh and enrollment modes.
	r := &store.AppAttestReceipt{ReceivedAt: received}
	verifyReceiptRecord(r, receiptVerificationContext{})
	if r.Outcome != "receipt_size" {
		t.Fatalf("refresh wrapper outcome %q", r.Outcome)
	}
	r = &store.AppAttestReceipt{ReceivedAt: received}
	verifyInitialReceiptRecord(r, receiptVerificationContext{})
	if r.Outcome != "receipt_size" {
		t.Fatalf("enrollment wrapper outcome %q", r.Outcome)
	}
}

func TestInitialReceiptBindsVerificationContextToEvidence(t *testing.T) {
	x := &Session{evidenceID: "evidence", key: &store.AppAttestShadowKey{KeyID: "key", AppID: "TEST.app", Environment: "development", PublicKey: []byte{4, 5, 6}}}
	hash := sha256.Sum256([]byte("client data"))
	before := time.Now().UTC()
	r := x.initialReceipt([]byte("not cbor"), hash)
	if r.ID == "" || r.KeyID != "key" || r.EvidenceID != "evidence" || r.ReceivedAt.Before(before) || r.Body != nil {
		t.Fatalf("receipt record %+v", r)
	}
	// Without an extractable receipt the record is kept as a failed decision.
	if r.Outcome != "receipt_size" || !r.NextAt.Equal(r.ReceivedAt.Add(time.Hour)) {
		t.Fatalf("outcome %q next %v", r.Outcome, r.NextAt)
	}
	var c receiptVerificationContext
	if err := json.Unmarshal(r.Context, &c); err != nil {
		t.Fatal(err)
	}
	if c.AppID != "TEST.app" || c.Environment != "development" || !bytes.Equal(c.PublicKey, []byte{4, 5, 6}) || c.ClientHash != hash {
		t.Fatalf("renewal context %+v", c)
	}
}

// failIfCalled fails the test if renewal reaches the network.
func failIfCalled(t *testing.T) *http.Client {
	return &http.Client{Transport: receiptRoundTrip(func(*http.Request) (*http.Response, error) {
		t.Error("renewal contacted Apple")
		return nil, errors.New("unexpected request")
	})}
}

func receiptContext(t *testing.T, appID, environment string) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(receiptVerificationContext{AppID: appID, Environment: environment})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestReceiptRenewalRefusesBeforeContactingApple(t *testing.T) {
	_, keyPath := receiptTestKey(t)
	badKey := filepath.Join(t.TempDir(), "bad.pem")
	if err := os.WriteFile(badKey, []byte("not a key"), 0600); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Hour)
	valid := receiptContext(t, "SLDQ2GJ6TL.io.darkbloom.provider", "production")
	for _, tc := range []struct {
		name string
		old  store.AppAttestReceipt
		cfg  Config
		want string
	}{
		{"unreadable context", store.AppAttestReceipt{Context: json.RawMessage(`{`), ExpiresAt: future}, Config{ReceiptKeyPath: keyPath}, "configuration_error"},
		{"expired receipt", store.AppAttestReceipt{Context: valid, ExpiresAt: time.Now().Add(-time.Minute)}, Config{ReceiptKeyPath: keyPath}, "receipt_expired"},
		{"team id not ten characters", store.AppAttestReceipt{Context: receiptContext(t, "SHORT.app", "production"), ExpiresAt: future}, Config{ReceiptKeyPath: keyPath}, "configuration_error"},
		{"missing key file", store.AppAttestReceipt{Context: valid, ExpiresAt: future}, Config{ReceiptKeyPath: filepath.Join(t.TempDir(), "missing.pem")}, "configuration_error"},
		{"invalid key file", store.AppAttestReceipt{Context: valid, ExpiresAt: future}, Config{ReceiptKeyPath: badKey}, "configuration_error"},
		{"unknown environment", store.AppAttestReceipt{Context: receiptContext(t, "SLDQ2GJ6TL.io.darkbloom.provider", "staging"), ExpiresAt: future}, Config{ReceiptKeyPath: keyPath}, "configuration_error"},
		{"historical enrollment receipt", store.AppAttestReceipt{Context: valid, Body: []byte("historic"), Outcome: "receipt_creation_time"}, Config{ReceiptKeyPath: keyPath}, "receipt_signature_or_chain"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.old.ID, tc.old.KeyID, tc.old.EvidenceID = "old", "key", "evidence"
			r := renewAppAttestReceipt(context.Background(), tc.old, tc.cfg, failIfCalled(t))
			if r.Outcome != tc.want || r.ParentID != "old" || r.KeyID != "key" || r.EvidenceID != "evidence" || r.ID == "" || r.ID == "old" {
				t.Fatalf("renewal record %+v", r)
			}
		})
	}
	expired := renewAppAttestReceipt(context.Background(), store.AppAttestReceipt{Context: valid, ExpiresAt: time.Now().Add(-time.Minute)}, Config{}, failIfCalled(t))
	if expired.NextAt.Before(time.Now().Add(364 * 24 * time.Hour)) {
		t.Fatal("expired receipt is retried before a year")
	}
	historic := renewAppAttestReceipt(context.Background(), store.AppAttestReceipt{Context: valid, Body: []byte("historic"), Outcome: "receipt_creation_time"}, Config{}, failIfCalled(t))
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
	cfg := Config{ReceiptKeyPath: keyPath, ReceiptKeyID: "TESTKEY"}
	respond := func(resp *http.Response, err error) *http.Client {
		return &http.Client{Transport: receiptRoundTrip(func(*http.Request) (*http.Response, error) { return resp, err })}
	}
	ok := func(body string) *http.Response {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}
	}
	if r := renewAppAttestReceipt(context.Background(), old, cfg, respond(nil, errors.New("dial failed"))); r.Outcome != "transport_error" || r.HTTPStatus != 0 {
		t.Fatalf("transport failure %+v", r)
	}
	r := renewAppAttestReceipt(context.Background(), old, cfg, respond(&http.Response{StatusCode: 200, Body: failingBody{}, Header: make(http.Header)}, nil))
	if r.Outcome != "response_read_error" || r.HTTPStatus != 200 {
		t.Fatalf("read failure %+v", r)
	}
	if r := renewAppAttestReceipt(context.Background(), old, cfg, respond(ok("%%% not base64"), nil)); r.Outcome != "malformed_receipt_response" || string(r.ResponseBody) != "%%% not base64" {
		t.Fatalf("malformed response %+v", r)
	}
	// A decodable body that is not an Apple-signed receipt is archived but
	// never becomes a verified refresh.
	body := base64.StdEncoding.EncodeToString([]byte("unsigned receipt"))
	r = renewAppAttestReceipt(context.Background(), old, cfg, respond(ok(body+"\n"), nil))
	if r.Outcome != "receipt_signature_or_chain" || string(r.Body) != "unsigned receipt" || r.HTTPStatus != 200 || !r.ExpiresAt.Equal(old.ExpiresAt) {
		t.Fatalf("unsigned refresh %+v", r)
	}
}

type receiptStorageFailures struct {
	*store.MemoryStore
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
			w := &appAttestReceiptWorker{s: &Service{metrics: m.metrics()}, store: tc.st}
			ticks := make(chan time.Time, 2)
			ticks <- time.Now()
			ticks <- time.Now()
			close(ticks)
			// A closed tick source ends the worker after the queued ticks.
			w.run(context.Background(), ticks, failIfCalled(t))
			if got := m.incrCount(tc.want); got != 2 {
				t.Fatalf("%s recorded %d times: %v", tc.want, got, m.incr)
			}
		})
	}
}
