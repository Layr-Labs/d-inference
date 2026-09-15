package api

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

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// Receipt renewal is independent of the DCDevice two-bit service. It remains
// off until dedicated server credentials are configured; no APNs mutation.
func (s *Server) startAppAttestReceiptWorker(ctx context.Context) {
	worker := s.newAppAttestReceiptWorker()
	if worker == nil {
		return
	}
	saferun.Go(s.logger, "appAttestReceiptRenewal", func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		worker.run(ctx, ticker.C, &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }})
	})
}

type appAttestReceiptWorker struct {
	s     *Server
	store store.AppAttestReceiptStore
	cfg   AppAttestShadowConfig
}

func (s *Server) newAppAttestReceiptWorker() *appAttestReceiptWorker {
	st, ok := store.As[store.AppAttestReceiptStore](s.store)
	cfg := s.appAttestShadow
	// The shadow switch controls new exchanges, not already archived receipts.
	if !ok || cfg.ReceiptKeyPath == "" || cfg.ReceiptKeyID == "" {
		return nil
	}
	return &appAttestReceiptWorker{s: s, store: st, cfg: cfg}
}

func (w *appAttestReceiptWorker) run(ctx context.Context, ticks <-chan time.Time, client *http.Client) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-ticks:
			if !ok || ctx.Err() != nil {
				return
			}
			operation, cancel := context.WithTimeout(ctx, 30*time.Second)
			old, err := w.store.ClaimAppAttestReceipt(operation, time.Now().UTC())
			if err == nil && old != nil {
				next := renewAppAttestReceipt(operation, *old, w.cfg, client)
				if e := w.store.SaveAppAttestReceiptRefresh(operation, next); e != nil {
					w.s.ddIncr("app_attest.receipt.archive_failed", nil)
				} else {
					w.s.ddIncr("app_attest.receipt.refresh", []string{"outcome:" + next.Outcome})
				}
			} else if err != nil {
				w.s.ddIncr("app_attest.receipt.storage_failed", nil)
			}
			cancel()
		}
	}
}

func renewAppAttestReceipt(ctx context.Context, old store.AppAttestReceipt, cfg AppAttestShadowConfig, client *http.Client) store.AppAttestReceipt {
	r := store.AppAttestReceipt{ID: uuid.NewString(), KeyID: old.KeyID, EvidenceID: old.EvidenceID, ParentID: old.ID, ReceivedAt: time.Now().UTC(), Context: old.Context, Details: json.RawMessage(`{}`), NextAt: time.Now().UTC().Add(time.Hour), ExpiresAt: old.ExpiresAt, Outcome: "configuration_error"}
	if !old.ExpiresAt.After(r.ReceivedAt) {
		r.Outcome = "receipt_expired"
		r.NextAt = r.ReceivedAt.Add(365 * 24 * time.Hour)
		return r
	}
	var c receiptVerificationContext
	if json.Unmarshal(old.Context, &c) != nil {
		return r
	}
	team := strings.SplitN(c.AppID, ".", 2)[0]
	if len(team) != 10 {
		return r
	}
	raw, err := os.ReadFile(cfg.ReceiptKeyPath)
	if err != nil {
		return r
	}
	key, err := jwt.ParseECPrivateKeyFromPEM(raw)
	if err != nil {
		return r
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": team, "iat": time.Now().Unix()})
	token.Header["kid"] = cfg.ReceiptKeyID
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
	response, err := client.Do(req)
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
	r.ReceivedAt = time.Now().UTC()
	verifyReceiptRecord(&r, c)
	return r
}
