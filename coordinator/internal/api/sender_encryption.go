// sender_encryption.go implements optional sender→coordinator request encryption.
//
// Senders fetch the coordinator's long-lived X25519 public key from
// GET /v1/encryption-key, NaCl-Box-seal their request body to it, and POST as
// Content-Type: application/darkbloom-sealed+json. The middleware below
// transparently decrypts the body so downstream handlers see plaintext, and
// re-seals the response (both buffered JSON and SSE streams) using the
// sender's ephemeral public key from the request envelope.
//
// Plaintext requests bypass this entirely — the middleware is a no-op when the
// sealed content type is not present.
//
// Wire format (request, JSON):
//   {
//     "kid": "abcd...",                  // identifies coordinator key (rotation)
//     "ephemeral_public_key": "<b64>",   // sender's ephemeral X25519 public key
//     "ciphertext": "<b64>"              // 24-byte nonce || NaCl Box sealed body
//   }
//
// Wire format (response, JSON, non-streaming):
//   {
//     "kid": "abcd...",
//     "ciphertext": "<b64>"              // sealed using sender's ephemeral pub
//                                        // + coordinator private; nonce prepended
//   }
//
// Wire format (SSE): each event is a single line of the form
//   data: <base64(nonce || sealed_event_bytes)>\n\n
// where the inner bytes are the original SSE event payload (everything between
// the previous `\n\n` boundary and the current one — including the leading
// `data: ` prefix when the upstream emitted one). The client base64-decodes,
// peels off the nonce, NaCl-Box-opens with the coordinator pubkey, and feeds
// the result back into a normal SSE parser.

package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strings"

	"golang.org/x/crypto/nacl/box"
)

// SealedContentType is the media type senders set on encrypted requests.
// The same media type is used on the response when the request was sealed.
const SealedContentType = "application/darkbloom-sealed+json"

// LegacySealedContentType is the pre-rename media type. Accepted during the
// transition period so existing clients sending the old header are not
// silently dropped to plaintext.
const LegacySealedContentType = "application/eigeninference-sealed+json"

// sealedRequestEnvelope is the on-the-wire shape of a sealed request body.
type sealedRequestEnvelope struct {
	KID                string `json:"kid"`
	EphemeralPublicKey string `json:"ephemeral_public_key"`
	Ciphertext         string `json:"ciphertext"`
}

// sealedResponseEnvelope is the on-the-wire shape of a non-streaming sealed
// response body.
type sealedResponseEnvelope struct {
	KID        string `json:"kid"`
	Ciphertext string `json:"ciphertext"`
}

// sealedCtxKey marks a request that was decrypted by sealedTransport. The
// sealing ResponseWriter consults the value via the closure; nothing else
// touches it, so a context-key suffices to avoid colliding with other keys.
type sealedCtxKeyT struct{}

var sealedCtxKey = sealedCtxKeyT{}

// isSealedContentType returns true when ct is the sealed media type, ignoring
// case (RFC 7231 §3.1.1.1) and any parameters like charset suffixes.
func isSealedContentType(ct string) bool {
	if ct == "" {
		return false
	}
	mt, _, err := mime.ParseMediaType(ct)
	if err != nil {
		trimmed := strings.TrimSpace(strings.SplitN(ct, ";", 2)[0])
		return strings.EqualFold(trimmed, SealedContentType) ||
			strings.EqualFold(trimmed, LegacySealedContentType)
	}
	return strings.EqualFold(mt, SealedContentType) ||
		strings.EqualFold(mt, LegacySealedContentType)
}

// handleEncryptionKey publishes the coordinator's X25519 public key plus a
// short kid that lets senders detect rotations. Public, no auth.
//
// Returns 503 when no key is configured — that's the signal to senders that
// the feature is unavailable in this environment (e.g. dev without a
// mnemonic), and they should fall back to plaintext.
func (s *Server) handleEncryptionKey(w http.ResponseWriter, r *http.Request) {
	if s.coordinatorKey == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_unavailable",
			"sender→coordinator encryption is not configured on this coordinator"))
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, map[string]any{
		"kid":        s.coordinatorKey.KID,
		"public_key": base64.StdEncoding.EncodeToString(s.coordinatorKey.PublicKey[:]),
		"algorithm":  "x25519-nacl-box",
	})
}

// sealedTransport wraps an inference handler so that requests sent with
// Content-Type: application/darkbloom-sealed+json are transparently
// decrypted before the handler sees them, and the handler's response is
// transparently sealed before it goes out on the wire.
//
// Plaintext requests bypass the wrapper entirely.
func (s *Server) sealedTransport(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !isSealedContentType(r.Header.Get("Content-Type")) {
			next(w, r)
			return
		}

		if s.coordinatorKey == nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_unavailable",
				"sender encryption is not configured on this coordinator — POST plaintext JSON instead"))
			return
		}

		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 16<<20))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"failed to read sealed request body"))
			return
		}

		var env sealedRequestEnvelope
		if err := json.Unmarshal(raw, &env); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_sealed_envelope",
				"sealed request body is not valid JSON: "+err.Error()))
			return
		}

		if env.KID != "" && env.KID != s.coordinatorKey.KID {
			writeJSON(w, http.StatusBadRequest, errorResponse("kid_mismatch",
				fmt.Sprintf("sealed request encrypted to kid %q but coordinator key is %q — refresh GET /v1/encryption-key", env.KID, s.coordinatorKey.KID)))
			return
		}

		ephemPubBytes, err := base64.StdEncoding.DecodeString(env.EphemeralPublicKey)
		if err != nil || len(ephemPubBytes) != 32 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_sealed_envelope",
				"ephemeral_public_key must be a base64 32-byte X25519 public key"))
			return
		}
		var ephemPub [32]byte
		copy(ephemPub[:], ephemPubBytes)

		ct2, err := base64.StdEncoding.DecodeString(env.Ciphertext)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_sealed_envelope",
				"ciphertext is not valid base64"))
			return
		}
		if len(ct2) < 24 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_sealed_envelope",
				"ciphertext is shorter than the 24-byte nonce prefix"))
			return
		}

		var nonce [24]byte
		copy(nonce[:], ct2[:24])

		coordPriv := s.coordinatorKey.PrivateKey
		plaintext, ok := box.Open(nil, ct2[24:], &nonce, &ephemPub, &coordPriv)
		if !ok {
			// Authenticated decryption failed — wrong key, tampered ciphertext,
			// or replayed nonce. Never silently fall through to plaintext.
			writeJSON(w, http.StatusBadRequest, errorResponse("decryption_failed",
				"sealed request could not be decrypted — verify GET /v1/encryption-key kid and that the body was sealed to it"))
			return
		}

		// Hand a fresh request to the downstream handler with the plaintext
		// body and a normal JSON content-type. r.Clone already deep-copies
		// the header map; we only need to swap content-type fields for the
		// downstream handler.
		r2 := r.Clone(context.WithValue(r.Context(), sealedCtxKey, ephemPub))
		r2.Body = io.NopCloser(bytes.NewReader(plaintext))
		r2.ContentLength = int64(len(plaintext))
		r2.Header.Set("Content-Type", "application/json")
		r2.Header.Del("Content-Length")

		sw := newSealingResponseWriter(w, &coordPriv, &ephemPub, s.coordinatorKey.KID)
		defer sw.finish()
		next(sw, r2)
	}
}

// sealingResponseWriter intercepts the inference handler's writes and seals
// them on the way out. It supports two modes, chosen by the upstream
// Content-Type at WriteHeader time:
//
//   - text/event-stream: per-event sealing. We buffer bytes from the inner
//     handler until we see a `\n\n` boundary, then NaCl-Box-seal the event
//     payload (everything before that boundary) and emit
//     `data: <b64(nonce||sealed)>\n\n`. The event boundary is preserved,
//     so the client's SSE parser still works without modification.
//   - everything else: full-body sealing. We buffer the entire response and
//     emit a single sealed envelope at finish().
type sealingResponseWriter struct {
	inner   http.ResponseWriter
	flusher http.Flusher

	coordPriv *[32]byte
	clientPub *[32]byte
	kid       string

	mode        sealMode
	statusCode  int
	bodyBuf     bytes.Buffer // non-streaming: accumulates full response
	sseScratch  bytes.Buffer // streaming: accumulates bytes until \n\n
	wroteHeader bool         // true once original handler called WriteHeader
}

type sealMode int

const (
	sealModeUnknown sealMode = iota
	sealModeBuffered
	sealModeSSE
)

func newSealingResponseWriter(w http.ResponseWriter, coordPriv, clientPub *[32]byte, kid string) *sealingResponseWriter {
	flusher, _ := w.(http.Flusher)
	return &sealingResponseWriter{
		inner:      w,
		flusher:    flusher,
		coordPriv:  coordPriv,
		clientPub:  clientPub,
		kid:        kid,
		statusCode: http.StatusOK,
	}
}

func (w *sealingResponseWriter) Header() http.Header { return w.inner.Header() }

func (w *sealingResponseWriter) WriteHeader(status int) {
	if w.wroteHeader {
		return
	}
	w.wroteHeader = true
	w.statusCode = status

	ct := w.inner.Header().Get("Content-Type")
	mt, _, _ := mime.ParseMediaType(ct)
	if strings.EqualFold(mt, "text/event-stream") {
		w.mode = sealModeSSE
		// Keep text/event-stream so the client's SSE parser is happy; the
		// per-event payload is what's sealed, not the framing.
		w.inner.Header().Set("X-Eigen-Sealed", "true")
		w.inner.Header().Set("X-Eigen-Sealed-Kid", w.kid)
		w.inner.Header().Del("Content-Length")
		w.inner.WriteHeader(status)
		if w.flusher != nil {
			w.flusher.Flush()
		}
		return
	}

	w.mode = sealModeBuffered
	// Defer WriteHeader for buffered mode — we don't know body length until
	// we seal at finish(), and we need to swap the content-type.
}

func (w *sealingResponseWriter) Write(p []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}

	switch w.mode {
	case sealModeSSE:
		return w.writeSSE(p)
	case sealModeBuffered:
		return w.bodyBuf.Write(p)
	default:
		// Mode is always set by WriteHeader (invoked above when not yet).
		return 0, errors.New("sealingResponseWriter: mode not set")
	}
}

func (w *sealingResponseWriter) Flush() {
	if w.flusher == nil {
		return
	}
	if w.mode == sealModeSSE {
		// Emit any complete events that have accumulated, but don't seal a
		// partial event — wait for the \n\n boundary.
		w.flushCompleteEvents()
		w.flusher.Flush()
	}
}

// writeSSE buffers incoming bytes and flushes one sealed event per `\n\n`.
func (w *sealingResponseWriter) writeSSE(p []byte) (int, error) {
	w.sseScratch.Write(p)
	w.flushCompleteEvents()
	if w.flusher != nil {
		w.flusher.Flush()
	}
	return len(p), nil
}

func (w *sealingResponseWriter) flushCompleteEvents() {
	for {
		buf := w.sseScratch.Bytes()
		idx := bytes.Index(buf, []byte("\n\n"))
		if idx < 0 {
			return
		}
		event := make([]byte, idx)
		copy(event, buf[:idx])
		w.sseScratch.Next(idx + 2)

		// sealBytes only fails if crypto/rand is broken (~unreachable). If it
		// ever does, we can't safely emit anything to a sealed stream — a
		// plaintext error frame would mis-frame the client's parser. Drop the
		// event and let the client time out / abort.
		sealed, err := sealBytes(event, w.clientPub, w.coordPriv)
		if err != nil {
			continue
		}
		fmt.Fprintf(w.inner, "data: %s\n\n", base64.StdEncoding.EncodeToString(sealed))
	}
}

// finish flushes any remaining buffered output and writes the final response.
func (w *sealingResponseWriter) finish() {
	switch w.mode {
	case sealModeSSE:
		// If the upstream produced a trailing event without a final \n\n
		// (rare — most servers terminate with `data: [DONE]\n\n`), seal and
		// emit it now to avoid losing data.
		if w.sseScratch.Len() > 0 {
			sealed, err := sealBytes(w.sseScratch.Bytes(), w.clientPub, w.coordPriv)
			w.sseScratch.Reset()
			if err == nil {
				fmt.Fprintf(w.inner, "data: %s\n\n", base64.StdEncoding.EncodeToString(sealed))
				if w.flusher != nil {
					w.flusher.Flush()
				}
			}
		}
		return

	case sealModeBuffered:
		sealed, err := sealBytes(w.bodyBuf.Bytes(), w.clientPub, w.coordPriv)
		if err != nil {
			// Best-effort error reply; we already promised the client a sealed
			// response so just close the connection by not writing anything.
			w.inner.Header().Del("Content-Type")
			w.inner.WriteHeader(http.StatusInternalServerError)
			return
		}
		envelope, _ := json.Marshal(sealedResponseEnvelope{
			KID:        w.kid,
			Ciphertext: base64.StdEncoding.EncodeToString(sealed),
		})
		w.inner.Header().Set("Content-Type", SealedContentType)
		w.inner.Header().Set("X-Eigen-Sealed", "true")
		w.inner.Header().Set("X-Eigen-Sealed-Kid", w.kid)
		w.inner.WriteHeader(w.statusCode)
		_, _ = w.inner.Write(envelope)
		return
	}
}

// sealBytes NaCl-Box-seals plaintext with a fresh nonce and returns
// nonce||ciphertext (the format consumed by the e2e package and the
// console-ui tweetnacl helper).
func sealBytes(plaintext []byte, recipientPub, senderPriv *[32]byte) ([]byte, error) {
	var nonce [24]byte
	if _, err := io.ReadFull(randReader, nonce[:]); err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	out := box.Seal(nonce[:], plaintext, &nonce, recipientPub, senderPriv)
	return out, nil
}

// randReader is overridable in tests. Production uses crypto/rand.
var randReader io.Reader = rand.Reader
