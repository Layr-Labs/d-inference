// Package request validates and prepares inference payloads without selecting a
// provider or owning request admission, billing, or cancellation.
package request

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// maxInferenceBodyBytes caps the plaintext inference request body. Without it
// the common (non-sealed) path does io.ReadAll(r.Body) with no limit, so any
// API-key holder could POST a multi-GB body and OOM the coordinator (the trusted
// TEE component).
//
// Sized to the PROVIDER WebSocket frame budget, not just OOM-safety: the
// coordinator encrypts rawBody and sends the base64 NaCl-box as ONE WS frame
// (consumer.go), and the Swift provider rejects frames over 32 MiB by tearing
// down the whole session + cancelling every unrelated in-flight request
// (CoordinatorClient.maxInboundMessageBytes). base64 adds ×4/3, so a 16 MiB body
// → ~21.3 MiB frame, comfortably under 32 MiB — the budget that provider cap was
// sized against, and identical to the sealed path (sender_encryption.go). A
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

// marshalForwardBody serializes a parsed request body for forwarding to a
// provider WITHOUT HTML escaping. encoding/json's default Marshal escapes the
// bytes '<', '>', and '&' into their 6-byte \uXXXX forms — a 6× per-character
// inflation that is meaningless on this path (the body is sealed and parsed as
// JSON by the provider, never embedded in HTML) yet can balloon a benign request
// — e.g. a prompt containing a long run of '<' — past the provider's
// single-frame WebSocket limit, tearing down its session. Disabling escaping
// keeps the re-marshaled body within a small constant of the (already
// size-capped) input. Mirrors NormalizeToolSchemas's own non-escaping round-trip.
func MarshalForwardBody(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	// Encoder.Encode appends a trailing newline the encrypted body shouldn't carry.
	return bytes.TrimSuffix(buf.Bytes(), []byte{'\n'}), nil
}

// forwardBody is the provider-bound request as the handler reshapes it: the
// decoded map every rewrite is applied to, plus the bytes that map was last
// serialized to. bytes starts as the caller's verbatim input, so a request
// that needs no rewrite at all reaches the provider byte-for-byte as sent;
// after any mutation the handler marks the body dirty and current() serializes
// once, however many rewrites preceded it.
type ForwardBody struct {
	Parsed map[string]any
	Bytes  []byte
	Dirty  bool
	// serialized reports that bytes is a coordinator serialization of parsed
	// (marshalForwardBody output) rather than the caller's verbatim input. Only
	// such bytes may stand in for a candidateProviderBody: a verbatim body can
	// differ from its re-serialization in whitespace, key order and string
	// escapes, and the size verdicts must keep measuring the serialized form.
	Serialized bool
}

// markDirty records that parsed has diverged from bytes.
func (b *ForwardBody) MarkDirty() { b.Dirty = true }

// current returns bytes reflecting every mutation so far, serializing only when
// something changed since the last serialization (or since the input was read).
func (b *ForwardBody) Current() ([]byte, error) {
	if !b.Dirty {
		return b.Bytes, nil
	}
	out, err := MarshalForwardBody(b.Parsed)
	if err != nil {
		return nil, err
	}
	b.Bytes, b.Dirty, b.Serialized = out, false, true
	return out, nil
}

// replace adopts bytes a helper already serialized from parsed (remote media
// inlining re-marshals after mutating parsed in place).
func (b *ForwardBody) Replace(serialized []byte) {
	b.Bytes, b.Dirty, b.Serialized = serialized, false, true
}

// decodeInferenceJSONObject preserves every JSON number as json.Number. The
// handlers re-marshal requests when they resolve aliases, lower endpoints,
// normalize stop sequences, or strip legacy-only fields. Decoding through
// float64 first would silently change precision-sensitive tool-schema values
// before the provider compiles them (for example, 2^53+1 becomes 2^53).
func DecodeInferenceJSONObject(rawBody []byte) (map[string]any, error) {
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
