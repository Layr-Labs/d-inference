package ownership

import (
	"context"
	"fmt"
	"strings"
)

// RustActivityProbe checks whether additive rust_coord tables hold work that
// blocks normal Go startup (plan §4.6 / §26).
type RustActivityProbe func(ctx context.Context) (active bool, detail string, err error)

// SQLRustActivity is the canonical probe query for operators / Go startup.
const SQLRustActivity = `
SELECT EXISTS (
  SELECT 1 FROM rust_coord.inference_jobs
  WHERE state NOT IN ('settled', 'released', 'settled_reviewed', 'released_reviewed')
     OR review_pending = TRUE
)
OR EXISTS (
  SELECT 1 FROM rust_coord.inference_attempts
  WHERE state NOT IN ('acknowledged', 'aborted', 'terminal_recorded')
)
OR EXISTS (
  SELECT 1 FROM rust_coord.outbox WHERE attempts < 100
);
`

// ApplyProbe runs probe and updates the gate's rust-active flag.
func (g *Gate) ApplyProbe(ctx context.Context, probe RustActivityProbe) error {
	if probe == nil {
		return nil
	}
	active, _, err := probe(ctx)
	if err != nil {
		// Missing schema is treated as inactive (pre-Rust). Real errors surface.
		if isUndefinedTable(err) {
			g.SetRustActive(false)
			return nil
		}
		return fmt.Errorf("ownership: rust activity probe: %w", err)
	}
	g.SetRustActive(active)
	return nil
}

func isUndefinedTable(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToLower(err.Error())
	return strings.Contains(s, "does not exist") ||
		strings.Contains(s, "undefined_table") ||
		strings.Contains(s, "42p01")
}
