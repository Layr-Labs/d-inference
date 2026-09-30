package conformance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	orModel         = "conformance-build"
	orAlias         = "conformance-alias"
	orAccount       = "conformance-selected"
	orInitial int64 = 1_000_000
	// Deliberately below the direct-consumer minimum and the provider custom rate.
	orCost int64 = 2 // floor(10*50,000/1,000,000) + floor(10*200,000/1,000,000)
)

type orFixture struct {
	t            *testing.T
	srv          Backend
	suite        Suite
	st           *store.MemoryStore
	ts           *httptest.Server
	client       *http.Client
	ctx          context.Context
	cancel       context.CancelFunc
	keys         map[string]string
	providers    []*orProvider
	model, alias string
}

func (s Suite) newORFixture(t *testing.T, holds bool) *orFixture {
	return s.newORModelFixture(t, holds, orModel, orAlias)
}

// Model strings here label synthetic catalog/transport state, never loaded artifacts.
func (s Suite) newORModelFixture(t *testing.T, holds bool, model, alias string) *orFixture {
	t.Helper()
	st := store.NewMemory(store.Config{})
	srv := s.NewServer(t, st, holds, orAccount)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	f := &orFixture{t: t, srv: srv, suite: s, st: st, ctx: ctx, cancel: cancel, keys: make(map[string]string), model: model, alias: alias}
	for _, acct := range []string{orAccount, "conformance-exempt", "conformance-other-service"} {
		role := store.RoleService
		if acct == "conformance-exempt" {
			role = ""
		}
		if err := st.CreateUser(&store.User{AccountID: acct, PrivyUserID: "did:fixture:" + acct, Role: role}); err != nil {
			t.Fatal(err)
		}
		key, err := st.CreateKeyForAccount(acct)
		if err != nil {
			t.Fatal(err)
		}
		f.keys[acct] = key
		if err := st.Credit(acct, orInitial, store.LedgerDeposit, "fixture"); err != nil {
			t.Fatal(err)
		}
	}
	key, err := st.CreateKeyForAccount(orAccount)
	if err != nil {
		t.Fatal(err)
	}
	f.keys["second"] = key
	for _, id := range []string{model, "conformance-retired", "conformance-staged"} {
		entry := &store.ModelRegistryEntry{ID: id, DisplayName: "Conformance", Quantization: "4bit", MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 1, Capabilities: []string{"tools", "reasoning"}, Status: "active", CreatedAt: time.Unix(1700000000, 0), Metadata: map[string]any{huggingFaceIDMetadataKey: "fixture/conformance", "private_fixture_marker": "must-not-leak"}}
		if id == "conformance-staged" {
			entry.Metadata["openrouter_is_ready"] = false
		}
		version := &store.ModelVersion{ModelID: id, Version: "v1", R2Prefix: s.ModelR2Prefix(id, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}
		if err := st.SetModelVersion(entry, version, []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}); err != nil {
			t.Fatal(err)
		}
		if err := st.PromoteModelVersion(id, "v1"); err != nil {
			t.Fatal(err)
		}
		if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: id, InputPrice: 50_000, OutputPrice: 200_000}); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.UpsertModelAlias(&store.ModelAlias{AliasID: alias, DisplayName: "Conformance alias", Active: true, DesiredBuild: model, RetiredBuilds: []string{"conformance-retired"}}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()
	f.ts = httptest.NewServer(srv.Handler())
	f.client = orLoopbackClient(t, f.ts.URL)
	t.Cleanup(func() {
		cancel()
		for _, p := range f.providers {
			p.close()
		}
		f.client.CloseIdleConnections()
		f.ts.CloseClientConnections()
		closed := make(chan struct{})
		go func() { f.ts.Close(); srv.Close(); close(closed) }()
		select {
		case <-closed:
		case <-time.After(3 * time.Second):
			t.Error("fixture server cleanup did not join")
		}
	})
	return f
}

// No endpoint option, proxy, SDK retry, cross-origin redirect, or DNS lookup.
// The exact loopback address was obtained from this fixture's listener.
func orLoopbackClient(t *testing.T, origin string) *http.Client {
	t.Helper()
	u, err := url.Parse(origin)
	if err != nil {
		t.Fatal(err)
	}
	if ip := net.ParseIP(u.Hostname()); ip == nil || !ip.IsLoopback() {
		t.Fatal("fixture origin must be a loopback literal")
	}
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		if address != u.Host {
			return nil, fmt.Errorf("blocked non-fixture destination")
		}
		return (&net.Dialer{Timeout: time.Second}).DialContext(ctx, network, address)
	}}
	return &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect blocked") }}
}

type orHTTPResult struct {
	resp      *http.Response
	err       error
	start     time.Time
	headersNS *int64
}

func (f *orFixture) startChat(key string, stream bool, extra map[string]any) (<-chan orHTTPResult, context.CancelFunc) {
	f.t.Helper()
	body := map[string]any{"model": f.alias, "messages": []any{map[string]any{"role": "user", "content": "synthetic fixture"}}, "stream": stream, "max_tokens": 32}
	for k, v := range extra {
		body[k] = v
	}
	b, err := json.Marshal(body)
	if err != nil {
		f.t.Fatal(err)
	}
	return f.startRawChat(key, b)
}

// Preserve caller field presence. Unlike startChat, this adds no request-body defaults.
func (f *orFixture) startRawChat(key string, b []byte) (<-chan orHTTPResult, context.CancelFunc) {
	f.t.Helper()
	ctx, cancel := context.WithCancel(f.ctx)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.ts.URL+"/v1/chat/completions", strings.NewReader(string(b)))
	if err != nil {
		f.t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	// Spoof controls are present for all callers; authenticated account alone selects SLA.
	req.Header.Set("X-OpenRouter", "true")
	req.Header.Set("HTTP-Referer", "https://openrouter.ai")
	req.Header.Set("X-Account-ID", orAccount)
	out := make(chan orHTTPResult, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		start := time.Now()
		resp, err := f.client.Do(req)
		var headers *int64
		if err == nil {
			headers = orStamp(start)
		}
		out <- orHTTPResult{resp: resp, err: err, start: start, headersNS: headers}
	}()
	f.t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(time.Second):
			f.t.Error("HTTP caller did not join")
		}
	})
	return out, cancel
}
func (f *orFixture) response(ch <-chan orHTTPResult) orHTTPResult {
	f.t.Helper()
	select {
	case r := <-ch:
		if r.err != nil {
			f.t.Fatal(r.err)
		}
		f.t.Cleanup(func() { r.resp.Body.Close() })
		return r
	case <-f.ctx.Done():
		f.t.Fatal("HTTP response deadline")
		return orHTTPResult{}
	}
}
func orReadBody(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, orMaxBody+1))
	if err != nil || len(b) > orMaxBody {
		t.Fatalf("bounded body: size=%d err=%v", len(b), err)
	}
	return b
}
func (f *orFixture) settled(account string, cost int64, count int) {
	f.t.Helper()
	orEventually(f.t, func() bool {
		return f.st.GetBalance(account) == orInitial-cost && len(f.st.UsageByConsumer(account)) == count && f.hold(account) == 0
	}, "balance, usage and holds settle")
	for _, p := range f.providers {
		orEventually(f.t, func() bool { rp := f.srv.Registry.GetProvider(p.id); return rp == nil || rp.PendingCount() == 0 }, "provider pending cleanup")
	}
}
func (f *orFixture) hold(account string) int64 {
	return f.srv.Outstanding(account)
}
func orEventually(t *testing.T, predicate func() bool, what string) {
	t.Helper()
	deadline := time.NewTimer(2 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		if predicate() {
			return
		}
		select {
		case <-tick.C:
		case <-deadline.C:
			t.Fatal(what)
		}
	}
}
