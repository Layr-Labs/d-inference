package ownership

import (
	"context"
	"encoding/json"
	"fmt"
)

// TerminalIngest records a protocol-v2 provider terminal against an existing
// Rust durable disposition without moving money a second time (plan §4.6).
// Used by the rollback-safe Go baseline when an offline provider reconnects
// after Rust→Go rollback with an unacknowledged terminal.
type TerminalIngest struct {
	JobID          string
	AttemptID      string
	TerminalDigest string
	SESignature    string
	Outcome        string
}

// TerminalDisposition is the stored Rust money/terminal outcome.
type TerminalDisposition struct {
	Disposition string // settled | released | settled_reviewed | released_reviewed | late | conflict
	AckPayload  json.RawMessage
}

// TerminalStore looks up and ACKs historical Rust terminals.
type TerminalStore interface {
	LookupRustTerminal(ctx context.Context, attemptID, digest string) (*TerminalDisposition, error)
	RecordLateTerminal(ctx context.Context, t TerminalIngest) error
}

// IngestTerminalACKs a replayed v2 terminal using the Rust disposition tables.
// Returns the ACK payload the coordinator should send to the provider.
// Never settles or releases funds — that already happened under Rust (or is review_pending).
func IngestTerminal(ctx context.Context, store TerminalStore, t TerminalIngest) (json.RawMessage, error) {
	if t.AttemptID == "" || t.TerminalDigest == "" {
		return nil, fmt.Errorf("ownership: terminal ingest missing attempt/digest")
	}
	disp, err := store.LookupRustTerminal(ctx, t.AttemptID, t.TerminalDigest)
	if err != nil {
		return nil, err
	}
	if disp != nil {
		if len(disp.AckPayload) > 0 {
			return disp.AckPayload, nil
		}
		return json.Marshal(map[string]any{
			"type":            "terminal_ack",
			"job_id":          t.JobID,
			"attempt_id":      t.AttemptID,
			"terminal_digest": t.TerminalDigest,
			"disposition":     disp.Disposition,
		})
	}
	// Unknown to Rust tables — record as late; do not auto-settle.
	if err := store.RecordLateTerminal(ctx, t); err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{
		"type":            "terminal_ack",
		"job_id":          t.JobID,
		"attempt_id":      t.AttemptID,
		"terminal_digest": t.TerminalDigest,
		"disposition":     "late",
	})
}
