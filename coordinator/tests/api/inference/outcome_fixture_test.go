package inference_test

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/crypto/nacl/box"
)

var outcomeEndpoints = []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"}

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

const senderTestMnemonic = "praise warfare warrior rebuild raven garlic kite blast crew impulse pencil hidden"

// sealRequest constructs a consumer-side NaCl envelope, not coordinator logic.
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

func contentChunkSSE(model, text string) string {
	data, _ := json.Marshal(text)
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"content":%s},"finish_reason":null}]}`+"\n\n", model, data)
}
