// Package receipt owns durable receipt renewal and its bounded Apple transport.
package receipt

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

type Config struct {
	KeyPath string
	KeyID   string
}

type Dependencies struct {
	Store     store.AppAttestReceiptStore
	Client    *http.Client
	Now       func() time.Time
	Increment func(string, []string)
}

type Worker struct {
	store     store.AppAttestReceiptStore
	client    *http.Client
	now       func() time.Time
	increment func(string, []string)
	cfg       Config
}

// New requires dedicated server credentials, independent of shadow rollout.
func New(cfg Config, deps Dependencies) *Worker {
	if deps.Store == nil || cfg.KeyPath == "" || cfg.KeyID == "" {
		return nil
	}
	if deps.Now == nil {
		deps.Now = time.Now
	}
	if deps.Client == nil {
		deps.Client = &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	if deps.Increment == nil {
		deps.Increment = func(string, []string) {}
	}
	return &Worker{store: deps.Store, client: deps.Client, now: deps.Now, increment: deps.Increment, cfg: cfg}
}

func (w *Worker) Run(ctx context.Context, ticks <-chan time.Time) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-ticks:
			if !ok || ctx.Err() != nil {
				return
			}
			operation, cancel := context.WithTimeout(ctx, 30*time.Second)
			old, err := w.store.ClaimAppAttestReceipt(operation, w.now().UTC())
			if err == nil && old != nil {
				next := w.Renew(operation, *old)
				if e := w.store.SaveAppAttestReceiptRefresh(operation, next); e != nil {
					w.increment("app_attest.receipt.archive_failed", nil)
				} else {
					w.increment("app_attest.receipt.refresh", []string{"outcome:" + next.Outcome})
				}
			} else if err != nil {
				w.increment("app_attest.receipt.storage_failed", nil)
			}
			cancel()
		}
	}
}

func (w *Worker) Renew(ctx context.Context, old store.AppAttestReceipt) store.AppAttestReceipt {
	r := store.AppAttestReceipt{ID: uuid.NewString(), KeyID: old.KeyID, EvidenceID: old.EvidenceID, ParentID: old.ID, ReceivedAt: w.now().UTC(), Context: old.Context, Details: json.RawMessage(`{}`), NextAt: w.now().UTC().Add(time.Hour), ExpiresAt: old.ExpiresAt, Outcome: "configuration_error"}
	var c VerificationContext
	if json.Unmarshal(old.Context, &c) != nil {
		return r
	}
	if old.Outcome == "receipt_creation_time" {
		// Append a recovery decision; retain the original failure unchanged.
		// No network call is made until the historical input passes validation.
		r.Body = old.Body
		verifyInitialReceiptRecord(&r, c)
		return r
	}
	if !old.ExpiresAt.After(r.ReceivedAt) {
		r.Outcome = "receipt_expired"
		r.NextAt = r.ReceivedAt.Add(365 * 24 * time.Hour)
		return r
	}
	team := strings.SplitN(c.AppID, ".", 2)[0]
	if len(team) != 10 {
		return r
	}
	raw, err := os.ReadFile(w.cfg.KeyPath)
	if err != nil {
		return r
	}
	key, err := jwt.ParseECPrivateKeyFromPEM(raw)
	if err != nil {
		return r
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": team, "iat": w.now().Unix()})
	token.Header["kid"] = w.cfg.KeyID
	auth, err := token.SignedString(key)
	if err != nil {
		return r
	}
	host := "https://data.appattest.apple.com"
	if c.Environment == "development" {
		host = "https://data-development.appattest.apple.com"
	} else if c.Environment != "production" {
		return r
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/v1/attestationData", bytes.NewBufferString(base64.StdEncoding.EncodeToString(old.Body)))
	if err != nil {
		return r
	}
	// Apple's endpoint-specific contract shows Authorization: <JWT>, including
	// its curl example. The linked APNs guide supplies JWT generation details.
	// https://developer.apple.com/documentation/devicecheck/assessing-fraud-risk
	req.Header.Set("Authorization", auth)
	req.Header.Set("Content-Type", "text/plain")
	response, err := w.client.Do(req)
	if err != nil {
		r.Outcome = "transport_error"
		return r
	}
	defer response.Body.Close()
	r.HTTPStatus = response.StatusCode
	body, err := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if err != nil {
		r.Outcome = "response_read_error"
		r.ResponseBody = body
		return r
	}
	if len(body) > 64*1024 {
		r.Outcome = "response_oversized"
		r.ResponseBody = body[:64*1024]
		return r
	}
	r.ResponseBody = body
	if response.StatusCode != 200 {
		r.Outcome = "http_error"
		if response.StatusCode == 304 {
			r.Outcome = "not_modified"
		}
		return r
	}
	r.Body, err = base64.StdEncoding.DecodeString(strings.TrimSpace(string(body)))
	if err != nil {
		r.Outcome = "malformed_receipt_response"
		return r
	}
	r.ReceivedAt = w.now().UTC()
	verifyReceiptRecord(&r, c)
	return r
}
