package store

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

const appAttestReceiptDDL = `
CREATE TABLE IF NOT EXISTS app_attest_receipts (
 id TEXT PRIMARY KEY,key_id TEXT NOT NULL,evidence_id TEXT NOT NULL,parent_id TEXT NOT NULL,
 received_at TIMESTAMPTZ NOT NULL,outcome TEXT NOT NULL,http_status INTEGER NOT NULL,
 details JSONB NOT NULL,context JSONB NOT NULL,next_at TIMESTAMPTZ NOT NULL,expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS app_attest_receipts_key ON app_attest_receipts(key_id,received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_receipts_recovery ON app_attest_receipts(key_id,received_at DESC) WHERE outcome='receipt_creation_time';
CREATE TABLE IF NOT EXISTS app_attest_receipt_blobs (
 receipt_id TEXT PRIMARY KEY REFERENCES app_attest_receipts(id),body BYTEA NOT NULL,response_body BYTEA NOT NULL
);
REVOKE ALL ON app_attest_receipt_blobs FROM PUBLIC;
CREATE TABLE IF NOT EXISTS app_attest_receipt_jobs (
 key_id TEXT PRIMARY KEY,receipt_id TEXT NOT NULL REFERENCES app_attest_receipts(id),next_at TIMESTAMPTZ NOT NULL,
 lease_until TIMESTAMPTZ,attempts BIGINT NOT NULL DEFAULT 0
);
`
