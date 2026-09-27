package api

import (
	"crypto/ed25519"
	"net/url"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Inference receipts are opt-in, signed records of one completed non-streaming
// chat completion (see docs/architecture/inference-receipts.md). The code is
// split by concern:
//
//   - inference_receipt_issuer.go: the configured signing identity, store
//     capability lookup and metrics (this file);
//   - inference_receipt_request.go: opt-in validation and pending-row
//     reservation before dispatch;
//   - inference_receipt_finalize.go: signing the winning attempt's output;
//   - inference_receipt_lookup.go: the public job, hash and key routes;
//   - inference_receipt_maintenance.go: stale-row recovery and expiry.
//
// Metrics are closed buckets with no job, nonce, key or account identifiers:
// inference_receipt.request{result}, inference_receipt.finalize{outcome} and
// inference_receipt.lookup{route,result}, each mirrored as a *_total counter.

const (
	defaultInferenceReceiptIssuer = "https://api.darkbloom.dev"
	// defaultInferenceReceiptExpiry is the public lookup window, measured from
	// reservation. Verifiers need long enough to settle disputes; the row is
	// pruned afterwards so the table stays bounded.
	defaultInferenceReceiptExpiry = 90 * 24 * time.Hour
)

// receiptIssuer is the coordinator's configured inference-receipt identity. A
// nil *receiptIssuer on Server means receipts are disabled. NewServer builds
// one only from a receipts.Config that AppConfig.Check has already validated.
type receiptIssuer struct {
	keys      *receipts.KeyRing
	origin    string        // issuer URL bound into every payload
	retention time.Duration // public lookup window from reservation
}

func newReceiptIssuer(cfg *receipts.Config, baseURL string) (*receiptIssuer, error) {
	if cfg == nil {
		return nil, nil
	}
	keys, err := cfg.KeyRing()
	if err != nil || keys == nil {
		return nil, err
	}
	return &receiptIssuer{
		keys:      keys,
		origin:    inferenceReceiptOrigin(baseURL),
		retention: defaultInferenceReceiptExpiry,
	}, nil
}

// publicKey returns the verification key for keyID; nil-safe so lookups of
// already-stored receipts report "key unavailable" when receipts are disabled.
func (i *receiptIssuer) publicKey(keyID string) (ed25519.PublicKey, bool) {
	if i == nil {
		return nil, false
	}
	return i.keys.PublicKey(keyID)
}

// inferenceReceiptOrigin derives the issuer bound into receipts from the
// coordinator's public base URL. Only the scheme and host are kept: verifiers
// compare it with the origin they fetched the public keys from.
func inferenceReceiptOrigin(baseURL string) string {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" {
		return defaultInferenceReceiptIssuer
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil {
		return defaultInferenceReceiptIssuer
	}
	parsed.Path, parsed.RawQuery, parsed.Fragment = "", "", ""
	return parsed.String()
}

// inferenceReceiptStore returns the backend's optional receipt capability.
func (s *Server) inferenceReceiptStore() (store.InferenceReceiptStore, bool) {
	if s.store == nil {
		return nil, false
	}
	return store.As[store.InferenceReceiptStore](s.store)
}

func (s *Server) recordInferenceReceiptRequest(result string) {
	s.ddIncr("inference_receipt.request", []string{"result:" + result})
	s.metrics.IncCounter("inference_receipt_request_total", MetricLabel{"result", result})
}

func (s *Server) recordInferenceReceiptFinalize(outcome string) {
	s.ddIncr("inference_receipt.finalize", []string{"outcome:" + outcome})
	s.metrics.IncCounter("inference_receipt_finalize_total", MetricLabel{"outcome", outcome})
}

func (s *Server) recordInferenceReceiptLookup(route, result string) {
	s.ddIncr("inference_receipt.lookup", []string{"route:" + route, "result:" + result})
	s.metrics.IncCounter("inference_receipt_lookup_total", MetricLabel{"route", route}, MetricLabel{"result", result})
}
