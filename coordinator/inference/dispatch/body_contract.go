package dispatch

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// MaxInferenceBodyBytes caps the plaintext inference request body. Without it
// the common (non-sealed) path does io.ReadAll(r.Body) with no limit, so any
// API-key holder could POST a multi-GB body and OOM the coordinator (the trusted
// TEE component).
//
// Sized to the PROVIDER WebSocket frame budget, not just OOM-safety: the
// coordinator encrypts rawBody and sends the base64 NaCl-box as ONE WS frame
// (prepare.go), and the Swift provider rejects frames over 32 MiB by tearing
// down the whole session + cancelling every unrelated in-flight request
// (CoordinatorClient.maxInboundMessageBytes). base64 adds ×4/3, so a 16 MiB body
// → ~21.3 MiB frame, comfortably under 32 MiB — the budget that provider cap was
// sized against, and identical to the sealed path (api/sender_encryption.go). A
// larger cap would let a request pass here only to disconnect the provider
// instead of returning a clean 413.
//
// The console already trims image history to the newest image turn
// (chat-messages.ts), but a single 4×10 MB turn (~53 MiB) still exceeds this and
// is undeliverable to any provider — aligning the per-turn UI image budget with
// the frame cap is tracked separately.
//
// This caps the body we READ. The body we actually SEAL can differ: the handlers
// re-marshal the parsed request after mutating it (max_tokens injection, tool
// normalization). The cap is therefore re-checked on that final body before
// encryption (see handleChatCompletions / handleGenericInference) using
// marshalForwardBody, which also disables HTML escaping so the re-marshal can't
// silently inflate a benign body past this limit.
const MaxInferenceBodyBytes = 16 << 20

// decodeInferenceJSONObject preserves every JSON number as json.Number. The
// handlers re-marshal requests when they resolve aliases, lower endpoints,
// normalize stop sequences, or strip legacy-only fields. Decoding through
// float64 first would silently change precision-sensitive tool-schema values
// before the provider compiles them (for example, 2^53+1 becomes 2^53).
func DecodeJSONObject(rawBody []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(rawBody))
	decoder.UseNumber()
	var parsed map[string]any
	if err := decoder.Decode(&parsed); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple JSON values")
		}
		return nil, err
	}
	return parsed, nil
}
