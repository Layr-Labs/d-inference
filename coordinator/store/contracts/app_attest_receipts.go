package contracts

import (
	"context"
	"encoding/json"
	"time"
)

type AppAttestReceipt struct {
	ID           string          `json:"id"`
	KeyID        string          `json:"key_id"`
	EvidenceID   string          `json:"evidence_id"`
	ParentID     string          `json:"parent_id"`
	ReceivedAt   time.Time       `json:"received_at"`
	Outcome      string          `json:"outcome"`
	HTTPStatus   int             `json:"http_status"`
	Body         []byte          `json:"-"` // exact CMS bytes, including invalid receipts
	ResponseBody []byte          `json:"-"` // complete bounded Apple HTTP response
	Details      json.RawMessage `json:"details"`
	Context      json.RawMessage `json:"context"`
	NextAt       time.Time       `json:"next_at"`
	ExpiresAt    time.Time       `json:"expires_at"`
}

type AppAttestReceiptStore interface {
	ClaimAppAttestReceipt(context.Context, time.Time) (*AppAttestReceipt, error)
	SaveAppAttestReceiptRefresh(context.Context, AppAttestReceipt) error
}
