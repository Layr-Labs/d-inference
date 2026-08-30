package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/receipt"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Inference receipts: coordinator-side verification and the public lookup.
//
// A v2 provider seals every completed inference into a canonical receipt
// (coordinator/receipt) whose SHA-256 hash rides in `response_hash` and is
// signed by the provider's Secure Enclave in `se_signature`. At completion the
// coordinator checks every binding it can see — receipt address, dispatched
// request digest, registered model weight hash, SE signature — and caches the
// receipt with its verdict for `GET /v1/receipts/{address}`. Receipts carry
// digests only, so the endpoint is public: anyone holding the plaintext
// transcript (the consumer, or an auditor the consumer hands it to) can bind
// the digests to content and replay the request against the same weights.

// receiptCacheCap bounds the in-memory receipt cache. Receipts are
// self-contained (the consumer receives the full receipt inline), so this
// cache is a lookup convenience with bounded memory, not a durability layer.
const receiptCacheCap = 8192

type storedReceipt struct {
	Address     string          `json:"address"`
	Receipt     json.RawMessage `json:"receipt"`
	SESignature string          `json:"se_signature,omitempty"`
	SEPublicKey string          `json:"se_public_key,omitempty"`
	Checks      receipt.Checks  `json:"checks"`
	ParseError  string          `json:"parse_error,omitempty"`
	CreatedAt   time.Time       `json:"created_at"`
}

type receiptCache struct {
	mu    sync.Mutex
	byKa  map[string]*storedReceipt
	order []string // FIFO eviction ring
}

func newReceiptCache() *receiptCache {
	return &receiptCache{byKa: make(map[string]*storedReceipt)}
}

func (c *receiptCache) put(r *storedReceipt) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.byKa[r.Address]; !exists {
		c.order = append(c.order, r.Address)
		for len(c.order) > receiptCacheCap {
			delete(c.byKa, c.order[0])
			c.order = c.order[1:]
		}
	}
	c.byKa[r.Address] = r
}

func (c *receiptCache) get(address string) (*storedReceipt, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.byKa[address]
	return r, ok
}

// recordReceipt verifies and caches a provider's receipt at inference
// completion. Verification failures never fail the request — the consumer
// already has the response and the receipt travels to them regardless; a
// failed binding is logged, counted, and visible on the receipt record so
// auditors (and future routing policy) can act on it.
func (s *Server) recordReceipt(
	providerID string,
	pr *registry.PendingRequest,
	msg *protocol.InferenceCompleteMessage,
) {
	sePublicKey, weightHash := s.registry.ReceiptContext(providerID, pr.Model)
	rec, checks, err := receipt.Verify(receipt.VerifyInput{
		ReceiptJSON:       []byte(msg.Receipt),
		ResponseHash:      msg.ResponseHash,
		SESignatureB64:    msg.SESignature,
		SEPublicKeyB64:    sePublicKey,
		DispatchedSHA256:  pr.DispatchedBodySHA256,
		CatalogWeightHash: weightHash,
	})
	stored := &storedReceipt{
		Address:     receipt.AddressOf([]byte(msg.Receipt)),
		Receipt:     json.RawMessage(msg.Receipt),
		SESignature: msg.SESignature,
		SEPublicKey: sePublicKey,
		Checks:      checks,
		CreatedAt:   time.Now().UTC(),
	}
	if err != nil {
		stored.ParseError = err.Error()
		// A malformed receipt must not be served as JSON verbatim.
		stored.Receipt = nil
	}
	s.receipts.put(stored)

	switch {
	case err != nil:
		s.logger.Warn("receipt malformed",
			"provider_id", providerID, "request_id", msg.RequestID, "error", err)
		s.ddIncr("receipt.receipt_malformed", []string{"model:" + pr.Model})
	case !checks.OK():
		s.logger.Warn("receipt binding check failed",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"model", pr.Model,
			"address_match", checks.AddressMatch,
			"request_digest_match", checks.RequestDigestMatch,
			"request_digest_checked", checks.RequestDigestChecked,
			"weight_hash_match", checks.ModelWeightHashMatch,
			"weight_hash_checked", checks.ModelWeightHashChecked,
			"signature_valid", checks.SignatureValid,
			"signature_checked", checks.SignatureChecked,
		)
		s.ddIncr("receipt.receipt_check_failed", []string{"model:" + pr.Model})
	default:
		// Sanity binding the receipt can only get wrong by lying: its model
		// and usage must agree with the completion message it rode in on.
		if rec.ModelID != pr.Model || rec.CompletionTokens != int(msg.Usage.CompletionTokens) {
			s.logger.Warn("receipt disagrees with completion message",
				"provider_id", providerID, "request_id", msg.RequestID,
				"receipt_model", rec.ModelID, "model", pr.Model)
			s.ddIncr("receipt.receipt_check_failed", []string{"model:" + pr.Model})
		} else {
			s.ddIncr("receipt.receipt_verified", []string{"model:" + pr.Model})
		}
	}
}

// handleGetReceipt serves GET /v1/receipts/{address}. Public: the record
// holds digests, a signature, and the provider's attestation public key —
// no prompt or response content.
func (s *Server) handleGetReceipt(w http.ResponseWriter, r *http.Request) {
	address := strings.ToLower(strings.TrimSpace(r.PathValue("address")))
	stored, ok := s.receipts.get(address)
	if !ok {
		writeJSON(w, http.StatusNotFound, errorResponse(
			"invalid_request_error", "receipt not found"))
		return
	}
	writeJSON(w, http.StatusOK, stored)
}
