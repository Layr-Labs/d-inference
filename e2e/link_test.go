package e2e

import (
	"bufio"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestIntegration_LargeRequestFragmentedDispatch proves the coordinator's
// fragmented data-lane write path against the REAL Swift provider: a request
// body above the 64 KiB fragment threshold is written as multiple WebSocket
// fragments (plus an empty FIN continuation), Network.framework must
// reassemble it into one message, and the provider must decrypt it and produce
// a first token. This is the change that hits every provider in the fleet the
// moment the coordinator deploys, so a Go-only test is not enough.
//
// This test is NOT part of the coordinator's unit gates (go test ./... under
// coordinator/ never runs it) and cannot run without the local testbed: a
// Postgres instance, a built Swift provider binary and a downloaded MLX model
// (see docs/developer/test.md, "E2E integration tests"). Run it from the
// repository root before shipping any change to the provider data-lane
// writer (coordinator/registry/provider_writer.go) — it is the ship gate for
// the fragmented write path:
//
//	make e2e-integration
//	go test ./e2e -run TestIntegration_LargeRequestFragmentedDispatch -v
//
// The root module's `go vet ./e2e/...` keeps it compiling.
func TestIntegration_LargeRequestFragmentedDispatch(t *testing.T) {
	s := startSuite(t)

	// Warm the model first: a cold load plus the attestation weight hashing
	// it triggers can exceed a short request's first-content budget on its
	// own (the coordinator answers 429 and the provider keeps loading), and
	// this test is about the wire, not cold starts. Retry until the slot is
	// warm and a small request succeeds.
	warmed := false
	for attempt := 0; attempt < 12 && !warmed; attempt++ {
		warm := postChatCompletions(t, s, "Say hi.", false, 1)
		_ = warm.Body.Close()
		if warm.StatusCode == http.StatusOK {
			warmed = true
			break
		}
		t.Logf("warm-up attempt %d returned %d; waiting for the model to load", attempt+1, warm.StatusCode)
		time.Sleep(5 * time.Second)
	}
	require.True(t, warmed, "model never became warm")

	// ~52 KiB of prompt: sealed + base64'd that is ~70 KiB on the wire, above
	// the 64 KiB fragment threshold. The filler is a single long run of '='
	// characters: byte-heavy for the wire but token-light for the model (BPE
	// vocabularies carry multi-character run tokens), so the request stays
	// well inside the provider's token-budget admission and the first-content
	// budget. English prose of the same byte size (~13k tokens) was rejected
	// by the provider's capacity admission on the testbed hardware.
	prompt := strings.Repeat("=", 52*1024) + "\n\nReply with the single word: done."

	resp := postChatCompletions(t, s, prompt, true, 4)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	payloadChunks := 0
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") || strings.HasSuffix(line, "[DONE]") {
			continue
		}
		if strings.Contains(line, `"delta":{`) && !strings.Contains(line, `"delta":{}`) {
			payloadChunks++
		}
	}
	require.NoError(t, scanner.Err())
	require.Greater(t, payloadChunks, 0, "expected at least one payload chunk from the provider")

	// The fragmented path must actually have run on this provider's link.
	var fragmented uint64
	var sawProvider bool
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		s.Coordinator.Registry.ForEachProvider(func(p *registry.Provider) {
			sawProvider = true
			if st := p.LinkStats(); st.FragmentedFramesOut > fragmented {
				fragmented = st.FragmentedFramesOut
			}
		})
		if fragmented > 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	require.True(t, sawProvider, "no provider registered")
	require.GreaterOrEqual(t, fragmented, uint64(1),
		"expected the inference_request to take the fragmented write path")

	// Bytes-by-kind counters must reflect the stream we just consumed.
	s.Coordinator.Registry.ForEachProvider(func(p *registry.Provider) {
		st := p.LinkStats()
		require.Greater(t, st.ChunkFramesIn, uint64(0), "chunk frames were not counted")
		require.Greater(t, st.HeartbeatFramesIn, uint64(0), "heartbeat frames were not counted")
		require.Greater(t, st.DataBytesOut, uint64(64<<10), "data bytes out below the fragment threshold: %d", st.DataBytesOut)
	})

}
