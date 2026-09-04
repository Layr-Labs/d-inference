package api

// A consumer that hangs up while its request frame is inside the provider
// socket write must not cost the provider connection. Before this change the
// writer CloseNow()'d the socket to return at the caller's deadline: the read
// loop failed (read_error), Disconnect flushed 502 into every other in-flight
// request on that provider (~60/provider in the 2026-08-31 wave), and the
// provider had to reconnect. Now the frame completes, the abandoned request is
// followed by a cancel on the same connection, and the sibling stream is
// untouched.
//
// Live harness: real coordinator (httptest + in-memory store + real registry)
// with deliberately small socket send buffers, one fake provider speaking the
// encrypted WS protocol whose reader PAUSES once the big frame starts arriving
// (so the coordinator's write is provably in flight when the consumer leaves),
// and two consumers on the same provider.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const (
	writeAbortSocketBufferBytes = 64 << 10
	// writeAbortPromptBytes is the '=' filler prompt; sealed and base64'd it
	// is a ~4 MiB data frame, far above what the loopback socket buffers
	// absorb even at these settings (~0.8 MiB measured in the registry's
	// ping-stall harness), so the coordinator's write is still in flight —
	// and blocked — while the fake provider's reader is paused.
	writeAbortPromptBytes = 3 << 20
	// writeAbortPauseAfterBytes: the provider stops reading once this much of
	// the big frame has arrived, until the test releases it.
	writeAbortPauseAfterBytes = 16 << 10
)

// writeAbortListener caps the kernel send buffer of every accepted provider
// socket so a multi-MiB frame cannot be absorbed by buffering.
type writeAbortListener struct{ net.Listener }

func (l writeAbortListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetWriteBuffer(writeAbortSocketBufferBytes)
	}
	return c, nil
}

var writeAbortRequestIDRe = regexp.MustCompile(`"request_id":"([^"]+)"`)

type writeAbortFrame struct {
	kind      string // "request" | "cancel"
	requestID string
}

// runWriteAbortProviderReader drives the fake provider's read loop. Frames
// are read message-by-message; the first inference_request frame larger than
// writeAbortPauseAfterBytes is reported on bigStarted (by request id, parsed
// from its first bytes) and the reader then blocks until resume is closed.
// Small inference requests are handed to onSmallRequest; every request and
// cancel frame is reported on frames in arrival order.
func runWriteAbortProviderReader(
	ctx context.Context,
	conn *websocket.Conn,
	pubKey string,
	frames chan<- writeAbortFrame,
	bigStarted chan<- string,
	resume <-chan struct{},
	onSmallRequest func(protocol.InferenceRequestMessage),
) error {
	paused := false
	chunk := make([]byte, 16<<10)
	for {
		_, r, err := conn.Reader(ctx)
		if err != nil {
			return err
		}
		var buf bytes.Buffer
		for {
			n, err := r.Read(chunk)
			buf.Write(chunk[:n])
			if !paused && buf.Len() >= writeAbortPauseAfterBytes &&
				bytes.HasPrefix(buf.Bytes(), []byte(`{"type":"inference_request"`)) {
				paused = true
				if m := writeAbortRequestIDRe.FindSubmatch(buf.Bytes()); m != nil {
					bigStarted <- string(m[1])
				}
				<-resume
			}
			if err == io.EOF {
				break
			}
			if err != nil {
				return err
			}
		}
		data := buf.Bytes()
		var env struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(data, &env)
		switch env.Type {
		case protocol.TypeAttestationChallenge:
			_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey))
		case protocol.TypeInferenceRequest:
			var req protocol.InferenceRequestMessage
			_ = json.Unmarshal(data, &req)
			frames <- writeAbortFrame{kind: "request", requestID: req.RequestID}
			if len(data) < writeAbortPauseAfterBytes {
				onSmallRequest(req)
			}
		case protocol.TypeCancel:
			var msg protocol.CancelMessage
			_ = json.Unmarshal(data, &msg)
			frames <- writeAbortFrame{kind: "cancel", requestID: msg.RequestID}
		}
	}
}

func TestIntegration_ClientHangupDuringInFlightProviderWriteKeepsConnection(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	collector, dd := attachTestDD(t, srv)
	ts := httptest.NewUnstartedServer(srv.Handler())
	ts.Listener = writeAbortListener{ts.Listener}
	ts.Start()
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pubKey := testPublicKeyB64()
	const model = "write-abort-model"

	// Provider link with a small receive buffer on its side too.
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
			if err != nil {
				return nil, err
			}
			if tc, ok := c.(*net.TCPConn); ok {
				_ = tc.SetReadBuffer(writeAbortSocketBufferBytes)
			}
			return c, nil
		},
	}
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPClient: &http.Client{Transport: transport}})
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	conn.SetReadLimit(-1)
	defer conn.CloseNow()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	waitForChallenge(t, ctx, conn, pubKey)
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("providers = %d, want 1", len(ids))
	}
	providerID := ids[0]
	// Two concurrent requests on the one provider.
	if p := reg.GetProvider(providerID); p != nil {
		p.Mu().Lock()
		p.BackendCapacity = &protocol.BackendCapacity{
			TotalMemoryGB:     64,
			GPUMemoryActiveGB: 8,
			Slots:             []protocol.BackendSlotCapacity{{Model: model, State: "running", MaxConcurrency: 4}},
		}
		p.Mu().Unlock()
	}

	frames := make(chan writeAbortFrame, 32)
	bigStarted := make(chan string, 1)
	resume := make(chan struct{})
	bStop := make(chan struct{})
	readerDone := make(chan error, 1)
	go func() {
		readerDone <- runWriteAbortProviderReader(ctx, conn, pubKey, frames, bigStarted, resume,
			func(req protocol.InferenceRequestMessage) {
				// B: stream a content chunk every 100 ms until told to finish.
				go func() {
					for i := 0; i < 300; i++ {
						select {
						case <-bStop:
							writeProviderFrame(ctx, conn, protocol.InferenceCompleteMessage{
								Type: protocol.TypeInferenceComplete, RequestID: req.RequestID,
								Usage: protocol.UsageInfo{PromptTokens: 5, CompletionTokens: i},
							})
							return
						case <-time.After(100 * time.Millisecond):
							writeProviderFrame(ctx, conn, testEncryptedChunk(t, req, pubKey, cancelTestChunkSSE(fmt.Sprintf("b%d ", i))))
						}
					}
				}()
			})
	}()

	// B streams on the provider for the whole scenario.
	respB, err := streamingChatRequest(ctx, ts.URL, model)
	if err != nil {
		t.Fatalf("request B: %v", err)
	}
	bFirst := make(chan struct{})
	bDone := make(chan string, 1)
	go func() {
		var body bytes.Buffer
		tmp := make([]byte, 4096)
		first := false
		for {
			n, err := respB.Body.Read(tmp)
			body.Write(tmp[:n])
			if !first && bytes.Contains(body.Bytes(), []byte("b0")) {
				first = true
				close(bFirst)
			}
			if err != nil {
				break
			}
		}
		_ = respB.Body.Close()
		bDone <- body.String()
	}()
	select {
	case <-bFirst:
	case <-time.After(15 * time.Second):
		t.Fatalf("request B never streamed its first chunk (status %d)", respB.StatusCode)
	}

	// A: a multi-MiB request whose frame is in the socket write when its
	// consumer hangs up.
	bodyA := `{"model":"` + model + `","messages":[{"role":"user","content":"` +
		strings.Repeat("=", writeAbortPromptBytes) + `"}],"stream":true}`
	ctxA, cancelA := context.WithCancel(ctx)
	defer cancelA()
	reqA, _ := http.NewRequestWithContext(ctxA, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(bodyA))
	reqA.Header.Set("Authorization", "Bearer test-key")
	aDone := make(chan error, 1)
	go func() {
		resp, err := http.DefaultClient.Do(reqA)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			err = fmt.Errorf("request A completed with status %d, want the hang-up to abort it", resp.StatusCode)
		}
		aDone <- err
	}()
	var aID string
	select {
	case aID = <-bigStarted:
	case err := <-aDone:
		t.Fatalf("request A ended before its frame reached the provider: %v", err)
	case <-time.After(20 * time.Second):
		t.Fatal("the provider never started receiving request A's frame")
	}
	// The provider has stopped reading: the rest of A's frame is stuck in the
	// coordinator's socket write. Now A's consumer hangs up.
	time.Sleep(300 * time.Millisecond)
	cancelA()
	select {
	case <-aDone:
	case <-time.After(10 * time.Second):
		t.Fatal("request A did not return after its consumer hung up")
	}
	// Let the provider drain the frame and observe what follows it.
	close(resume)

	sawRequestA := false
	deadline := time.After(20 * time.Second)
	for sawCancelA := false; !sawCancelA; {
		select {
		case f := <-frames:
			if f.requestID != aID {
				continue
			}
			switch f.kind {
			case "request":
				sawRequestA = true
			case "cancel":
				if !sawRequestA {
					t.Fatal("cancel for A arrived before A's request frame")
				}
				sawCancelA = true
			}
		case err := <-readerDone:
			t.Fatalf("provider read loop died (%v): the coordinator closed the connection for an abandoned in-flight frame", err)
		case <-deadline:
			t.Fatalf("no cancel followed request A's frame (request seen: %v)", sawRequestA)
		}
	}

	// B was never disturbed: it finishes on the same connection.
	close(bStop)
	var bodyB string
	select {
	case bodyB = <-bDone:
	case <-time.After(15 * time.Second):
		t.Fatal("request B did not finish after the provider completed it")
	}
	if respB.StatusCode != http.StatusOK {
		t.Fatalf("request B status = %d, want 200", respB.StatusCode)
	}
	if strings.Contains(bodyB, "provider disconnected") {
		t.Fatalf("request B received the provider-disconnected error: the abandoned write killed the provider connection; body = %s", bodyB[len(bodyB)-min(len(bodyB), 400):])
	}
	if !strings.Contains(bodyB, "[DONE]") {
		t.Fatalf("request B did not complete cleanly; body tail = %s", bodyB[len(bodyB)-min(len(bodyB), 400):])
	}
	if reg.GetProvider(providerID) == nil {
		t.Fatal("the provider was disconnected by the abandoned write")
	}
	packets := dd.packets(collector)
	if got := findMetrics(packets, "ws.disconnects"); len(got) != 0 {
		t.Fatalf("ws.disconnects emitted: %v", got)
	}
	requireMetricWithTags(t, packets, "provider.writer_inflight_abort", "reason:client_gone")
	requireMetricWithTags(t, packets, metricCancelSent, "cause:"+cancelCauseWriteAborted, "model:"+model)

	conn.Close(websocket.StatusNormalClosure, "")
	<-readerDone
}
