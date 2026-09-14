package api

import (
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"net/http"
)

func markResponseTerminalWrite(w http.ResponseWriter, terminals response.Terminals, n, expected int, err error) {
	if err != nil || n != expected || terminals.First == "" {
		return
	}
	// Plaintext acceptance by this buffer is not an outer transport write.
	// The sealing writer records each terminal after writing its ciphertext.
	if _, sealed := w.(*sealingResponseWriter); sealed {
		return
	}
	if o := outcomeForWriter(w); o != nil {
		o.mu.Lock()
		defer o.mu.Unlock()
		for _, terminal := range []string{terminals.First, terminals.Conflicting} {
			if terminal == "" {
				continue
			}
			if o.record.ResponseTerminal == "" || o.record.ResponseTerminal == "unknown" {
				o.record.ResponseTerminal = terminal
			} else if o.record.ResponseTerminal != terminal {
				o.record.EvidenceConflict = true
			}
		}
		o.record.EgressCompleted = true
	}
}

func markOutcomePanic(r *http.Request) {
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		o.record.RawStage = "handler"
		o.record.RawReason = "handler_panic"
		o.mu.Unlock()
	}
}
