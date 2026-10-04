package conformance

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

type orDispatch struct {
	request protocol.InferenceRequestMessage
	body    map[string]any
}
type orProvider struct {
	f           *orFixture
	conn        *websocket.Conn
	pub, id     string
	privateKey  [32]byte
	requests    chan orDispatch
	cancels     chan string
	acks        chan string
	barriers    atomic.Int32
	faults      chan error
	ready, done chan struct{}
	count       atomic.Int32
	mu          sync.Mutex
	closeOnce   sync.Once
}

func (f *orFixture) provider(version string) *orProvider {
	f.t.Helper()
	p := &orProvider{f: f, pub: testkit.PublicKeyB64(), requests: make(chan orDispatch, 8), cancels: make(chan string, 8), acks: make(chan string, 2), faults: make(chan error, 1), ready: make(chan struct{}), done: make(chan struct{})}
	pair, ok := testkit.ProviderKeys.Load(p.pub)
	if !ok {
		f.t.Fatal("missing fixture provider key")
	}
	p.privateKey = pair.(testkit.ProviderKeyPair).Private
	conn, _, err := websocket.Dial(f.ctx, "ws"+strings.TrimPrefix(f.ts.URL, "http")+"/ws/provider", &websocket.DialOptions{HTTPClient: f.client})
	if err != nil {
		f.t.Fatal(err)
	}
	p.conn = conn
	f.providers = append(f.providers, p)
	go p.read()
	yes := true
	p.write(protocol.RegisterMessage{Type: protocol.TypeRegister, Hardware: protocol.Hardware{MachineModel: "fixture", ChipName: "Apple M3 Max", MemoryGB: 64}, Models: []protocol.ModelInfo{{ID: f.model, WeightHash: testHash, ModelType: "chat", Quantization: "4bit", TemplateRenderOK: &yes}}, Backend: "mlx-swift", Version: version, DecodeTPS: 200, PublicKey: p.pub, EncryptedResponseChunks: true, PrivacyCapabilities: testkit.PrivacyCaps()})
	select {
	case <-p.ready:
	case e := <-p.faults:
		f.t.Fatal(e)
	case <-f.ctx.Done():
		f.t.Fatal("registration barrier deadline")
	}
	for _, id := range f.srv.Registry.ProviderIDs() {
		rp := f.srv.Registry.GetProvider(id)
		rp.Mu().Lock()
		match := rp.PublicKey == p.pub
		rp.Mu().Unlock()
		if match {
			p.id = id
			break
		}
	}
	if p.id == "" {
		f.t.Fatal("registration barrier without provider")
	}
	// Explicit test-only trust bypass. This does not qualify attestation.
	f.srv.Registry.SetTrustLevel(p.id, registry.TrustHardware)
	f.srv.Registry.RecordChallengeSuccess(p.id)
	rp := f.srv.Registry.GetProvider(p.id)
	rp.Mu().Lock()
	rp.AccountID = "conformance-provider"
	rp.PrefillTPS = 6000
	// Explicit synthetic warm capacity, legacy seq=0 (no probe protocol).
	rp.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: f.model, State: "idle", MaxConcurrency: 1, ActiveTokenBudgetMax: 200_000}}}
	rp.Mu().Unlock()
	if err := f.st.SetModelPrice(store.ModelPrice{AccountID: "conformance-provider", Model: f.model, InputPrice: 50_000, OutputPrice: 10_000_000}); err != nil {
		f.t.Fatal(err)
	}
	return p
}
func (p *orProvider) read() {
	defer close(p.done)
	var ready sync.Once
	fail := func(err error) {
		select {
		case p.faults <- err:
		default:
		}
	}
	for {
		_, data, err := p.conn.Read(p.f.ctx)
		if err != nil {
			return
		}
		var env struct {
			Type string `json:"type"`
		}
		if err = json.Unmarshal(data, &env); err != nil {
			fail(err)
			return
		}
		switch env.Type {
		case protocol.TypeAttestationChallenge:
			ready.Do(func() { close(p.ready) })
		case protocol.TypeInferenceRequest:
			var req protocol.InferenceRequestMessage
			if err = json.Unmarshal(data, &req); err != nil {
				fail(err)
				return
			}
			if req.EncryptedBody == nil {
				fail(errORPlaintext)
				return
			}
			body, err := e2e.DecryptWithPrivateKey(&e2e.EncryptedPayload{EphemeralPublicKey: req.EncryptedBody.EphemeralPublicKey, Ciphertext: req.EncryptedBody.Ciphertext}, p.privateKey)
			if err != nil {
				fail(err)
				return
			}
			var decoded map[string]any
			if err = json.Unmarshal(body, &decoded); err != nil {
				fail(err)
				return
			}
			p.count.Add(1)
			select {
			case p.requests <- orDispatch{req, decoded}:
			case <-p.f.ctx.Done():
				return
			}
		case protocol.TypeProviderDrainAck:
			var ack protocol.ProviderDrainMessage
			if err = json.Unmarshal(data, &ack); err != nil {
				fail(err)
				return
			}
			select {
			case p.acks <- ack.RequestID:
			case <-p.f.ctx.Done():
				return
			}
		case protocol.TypeCancel:
			var c protocol.CancelMessage
			if err = json.Unmarshal(data, &c); err != nil {
				fail(err)
				return
			}
			select {
			case p.cancels <- c.RequestID:
			case <-p.f.ctx.Done():
				return
			}
		}
	}
}

var errORPlaintext = errors.New("provider received unencrypted request")

func (p *orProvider) write(v any) {
	p.f.t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		p.f.t.Fatal(err)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if err = p.conn.Write(p.f.ctx, websocket.MessageText, data); err != nil {
		p.f.t.Fatal(err)
	}
}
func (p *orProvider) next() orDispatch {
	p.f.t.Helper()
	select {
	case r := <-p.requests:
		return r
	case e := <-p.faults:
		p.f.t.Fatal(e)
	case <-p.f.ctx.Done():
		p.f.t.Fatal("provider dispatch deadline")
	}
	return orDispatch{}
}
func (p *orProvider) chunk(r orDispatch, sse string) {
	p.f.t.Helper()
	p.write(testkit.EncryptedChunk(p.f.t, r.request, p.pub, sse))
}
func (p *orProvider) complete(r orDispatch) {
	p.write(protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: r.request.RequestID, Usage: protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 10}})
}
func (p *orProvider) failure(r orDispatch, status int, code protocol.InferenceFailureCode, reason string) {
	p.write(protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError, RequestID: r.request.RequestID, StatusCode: status, FailureCode: code, ErrorReason: reason, Error: "synthetic provider failure"})
}
func (p *orProvider) success(r orDispatch, stream, usage bool) {
	if stream {
		p.chunk(r, orModelFrame(p.f.model, `{"role":"assistant"}`, "null"))
		p.chunk(r, orModelFrame(p.f.model, `{"content":"héllo"}`, "null"))
		terminal := orModelFrame(p.f.model, `{}`, `"stop"`)
		if usage {
			terminal = strings.Replace(terminal, `}]}`, `}],"usage":{"prompt_tokens":10,"completion_tokens":10,"total_tokens":20}}`, 1)
		}
		p.chunk(r, terminal+"data: [DONE]\n\n")
	} else {
		p.chunk(r, `{"id":"fixture-response","object":"chat.completion","created":1700000000,"model":"conformance-build","choices":[{"index":0,"message":{"role":"assistant","content":"héllo"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":10,"total_tokens":20}}`)
	}
	p.complete(r)
}
func (p *orProvider) close() {
	p.closeOnce.Do(func() { p.conn.CloseNow() })
	select {
	case <-p.done:
	case <-time.After(time.Second):
		p.f.t.Error("provider reader did not join")
	}
	testkit.ProviderKeys.Delete(p.pub)
}

// barrier fences this provider only after the scenario has finished routing.
// The protocol ack joins all earlier asynchronous completion workers and is
// ordered behind earlier control frames in the coordinator's socket writer.
func (p *orProvider) barrier() {
	p.f.t.Helper()
	orEventually(p.f.t, func() bool { return p.f.srv.Inflight() == 0 }, "HTTP handlers quiesce before barrier")
	id := fmt.Sprintf("conformance-barrier-%d", p.barriers.Add(1))
	p.write(protocol.ProviderDrainMessage{Type: protocol.TypeProviderDrain, RequestID: id})
	select {
	case got := <-p.acks:
		if got != id {
			p.f.t.Fatal("wrong drain acknowledgement")
		}
	case e := <-p.faults:
		p.f.t.Fatal(e)
	case <-p.f.ctx.Done():
		p.f.t.Fatal("terminal worker drain deadline")
	}
}
func orNoCancel(t *testing.T, p *orProvider) {
	t.Helper()
	p.barrier()
	select {
	case id := <-p.cancels:
		t.Fatalf("unexpected cancel for %s", id)
	default:
	}
}

// Normal models_update ingress, with a state barrier after the synchronous
// handler has accepted the advertisement. It does not claim a model loaded.
func (p *orProvider) advertiseTools(enabled bool) {
	p.f.t.Helper()
	advertised := []string{}
	if enabled {
		advertised = append(advertised, p.f.model)
	}
	yes := true
	p.write(protocol.ModelsUpdateMessage{Type: protocol.TypeModelsUpdate, Models: []protocol.ModelInfo{{ID: p.f.model, WeightHash: testHash, ModelType: "nemotron_h", Quantization: "4bit", TemplateRenderOK: &yes}}, ToolConstraintProtocol: 1, ToolConstraintModels: advertised})
	orEventually(p.f.t, func() bool {
		provider := p.f.srv.Registry.GetProvider(p.id)
		if provider == nil {
			return false
		}
		provider.Mu().Lock()
		defer provider.Mu().Unlock()
		_, present := provider.ToolConstraintModels[p.f.model]
		return provider.ToolConstraintProtocol == 1 && present == enabled
	}, "models_update capability accepted")
}
