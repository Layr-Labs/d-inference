package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"golang.org/x/crypto/nacl/box"
)

var outcomeEndpoints = []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"}

const senderTestMnemonic = "praise warfare warrior rebuild raven garlic kite blast crew impulse pencil hidden"

func awaitRequestOutcomes(t *testing.T, s store.RequestOutcomeStore, n int) []store.RequestOutcomeRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		rows, err := s.RequestOutcomes(context.Background(), time.Time{}, time.Now().Add(time.Second), 100)
		if err != nil {
			t.Fatal(err)
		}
		done := len(rows) == n
		for _, r := range rows {
			done = done && r.FinalizedAt != nil
		}
		if done {
			return rows
		}
		if time.Now().After(deadline) {
			t.Fatalf("request ledger did not settle: %+v", rows)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func contentChunkSSE(model, text string) string {
	data, _ := json.Marshal(text)
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"content":%s},"finish_reason":null}]}`+"\n\n", model, data)
}

func sealRequest(t *testing.T, plaintext []byte, coordPub [32]byte, kid string) ([]byte, *[32]byte, *[32]byte) {
	t.Helper()
	ephemPub, ephemPriv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		t.Fatal(err)
	}
	sealed := box.Seal(nonce[:], plaintext, &nonce, &coordPub, ephemPriv)
	env, _ := json.Marshal(map[string]any{
		"kid":                  kid,
		"ephemeral_public_key": base64.StdEncoding.EncodeToString(ephemPub[:]),
		"ciphertext":           base64.StdEncoding.EncodeToString(sealed),
	})
	return env, ephemPub, ephemPriv
}

type terminalOutcomeWriter struct {
	header         http.Header
	body           strings.Builder
	mode           string
	failAt, writes int
}

func (w *terminalOutcomeWriter) Header() http.Header { return w.header }
func (w *terminalOutcomeWriter) WriteHeader(int)     {}
func (w *terminalOutcomeWriter) Flush()              {}
func (w *terminalOutcomeWriter) Write(p []byte) (int, error) {
	w.writes++
	if w.failAt > 0 && w.writes != w.failAt {
		return w.body.Write(p)
	}
	switch w.mode {
	case "short":
		return w.body.Write(p[:len(p)-1])
	case "error":
		return 0, errors.New("consumer disconnected")
	case "full with error":
		n, _ := w.body.Write(p)
		return n, errors.New("consumer disconnected")
	default:
		return w.body.Write(p)
	}
}

func terminalOutcomeServer(t *testing.T) (*Server, *memory.MemoryStore) {
	t.Helper()
	st := memory.NewMemory(store.Config{})
	t.Setenv(envProfiler, "off")
	logger := quietLogger()
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	return srv, st
}

func terminalOutcomePending(srv *Server, r *http.Request, provider string) *registry.PendingRequest {
	rp := srv.observation.NewRequestProfile(r, "m", "m", true)
	ap := rp.NewAttempt("terminal-attempt", 0, "")
	ap.Winning.Store(true)
	status := "success"
	if provider == "error" {
		status = "error"
	}
	ap.SetOutcome(status, "", "", provider, "")
	return &registry.PendingRequest{RequestID: ap.RequestID, ConsumerEndpoint: r.URL.Path, Model: "m", Profile: ap}
}
