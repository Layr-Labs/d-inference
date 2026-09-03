package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/tools/systemmap/prose"
)

// These tests run the enricher end to end against a real HTTP server that speaks
// the Messages API, in a real repository layout, writing a real prose file. The
// model is the only thing stood in for, because it is the only part that cannot be
// run locally — everything the program actually has to get right (what it sends,
// what it accepts, what it writes, what it refuses to do without a key) is
// exercised for real.

// fakeAPI is the Messages API, answered by a script. It records every prompt so a
// test can assert what the model was told, which is where the interesting
// properties live: a rejection has to name the rule that was broken.
type fakeAPI struct {
	*httptest.Server
	mu      sync.Mutex
	calls   []apiRequest
	reply   func(call int, req apiRequest) (status int, body string)
	nextErr int
}

func newFakeAPI(t *testing.T, reply func(call int, req apiRequest) (int, string)) *fakeAPI {
	t.Helper()
	api := &fakeAPI{reply: reply}
	api.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/messages" {
			t.Errorf("enricher posted to %s, want /v1/messages", r.URL.Path)
		}
		if got := r.Header.Get("x-api-key"); got != "test-key" {
			t.Errorf("api key header = %q", got)
		}
		if got := r.Header.Get("anthropic-version"); got == "" {
			t.Error("no anthropic-version header")
		}
		var req apiRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("request body: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		api.mu.Lock()
		call := len(api.calls)
		api.calls = append(api.calls, req)
		api.mu.Unlock()

		status, text := api.reply(call, req)
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(status)
		if status != http.StatusOK {
			_, _ = w.Write([]byte(text))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"content":     []map[string]string{{"type": "text", "text": text}},
			"stop_reason": "end_turn",
		})
	}))
	t.Cleanup(api.Close)
	return api
}

func (a *fakeAPI) prompts() []apiRequest {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]apiRequest(nil), a.calls...)
}

// enrichHarness is a throwaway repository: an overlay with two hand-written
// entries of each kind (the style anchors), a source file for a route to cite, and
// a manifest.
type enrichHarness struct {
	dir string
	s   settings
}

func newEnrichHarness(t *testing.T, plan manifest) enrichHarness {
	t.Helper()
	dir := t.TempDir()
	mustWrite := func(rel string, content []byte) {
		path := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, content, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	docs := map[string]string{}
	for _, field := range prose.DocFields {
		docs[field] = "Hand-written " + field + "."
	}
	overlay, err := json.Marshal(map[string]any{
		"routes": map[string]any{
			"GET /v1/models": map[string]string{
				"description": "Returns the models the fleet can currently serve.",
				"details":     "Reads the registry and filters by live provider capability.",
			},
		},
		"labels":  map[string]string{"mem.warmPool": "Warm pool controller"},
		"depDocs": map[string]any{"pg.api_keys": docs},
		// The overlay carries much more than prose; the enricher must ignore it.
		"clusters": map[string]any{"api": []string{"mem.warmPool"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	mustWrite("docs/reference/api-map/overlay.json", overlay)
	mustWrite("api/handlers.go", []byte(`package api

func (s *Server) handleAliases(w http.ResponseWriter, r *http.Request) {
	// A distinctive line the prompt must carry: aliases are read through the cache.
	s.cache.fill(r.Context())
}
`))
	raw, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	mustWrite("tmp/plan.json", raw)

	return enrichHarness{dir: dir, s: settings{
		root:      dir,
		manifest:  "tmp/plan.json",
		prosePath: "docs/reference/api-map/prose.json",
		overlay:   "docs/reference/api-map/overlay.json",
		model:     "claude-test-5",
		keyEnv:    "ENRICH_TEST_KEY",
		maxTokens: 512,
		workers:   2,
		attempts:  3,
		timeout:   30 * time.Second,
		quiet:     true,
	}}
}

func (h enrichHarness) prose(t *testing.T) *prose.File {
	t.Helper()
	f, err := prose.Load(filepath.Join(h.dir, h.s.prosePath))
	if err != nil {
		t.Fatalf("generated prose does not load back: %v", err)
	}
	return f
}

func routeReq() prose.Request {
	return prose.Request{
		Key:  "GET /v1/aliases",
		Kind: "route",
		Hash: "aaaabbbbccccddddeeeeffff",
		Cite: "api/handlers.go:3",
		Facts: map[string]any{
			"method": "GET", "path": "/v1/aliases", "handler": "handleAliases",
			"namespace": "Consumer API", "auth": "api_key",
			"dependencies": []string{"mem.aliases R", "mem.cache W"},
		},
	}
}

func labelReq() prose.Request {
	return prose.Request{
		Key: "mem.cache", Kind: "label", Hash: "111122223333444455556666",
		Facts: map[string]any{"id": "mem.cache", "category": "mem", "symbols": []string{"field api:Server.cache"}},
	}
}

func nodeReq() prose.Request {
	return prose.Request{
		Key: "mem.cache", Kind: "node", Hash: "777788889999aaaabbbbcccc",
		Facts: map[string]any{
			"id": "mem.cache", "category": "mem", "symbols": []string{"field api:Server.cache"},
			"access": []string{"Consumer API W"},
		},
	}
}

// answerFor is a well-behaved model: it writes the fields its kind asks for and
// nothing else.
func answerFor(req apiRequest) string {
	prompt := req.Messages[0].Content
	switch {
	case strings.Contains(prompt, `kind "route"`):
		return `{"description": "Returns the alias table for the calling account.", "details": "Reads the alias map and fills the request cache."}`
	case strings.Contains(prompt, `kind "label"`):
		return "```json\n{\"label\": \"Alias cache\"}\n```" // a fenced reply is tolerated
	default:
		fields := map[string]string{}
		for _, f := range prose.DocFields {
			fields[f] = "Generated " + f + " text for the alias cache."
		}
		raw, _ := json.Marshal(fields)
		return string(raw)
	}
}

func TestEnrichWritesMissingProse(t *testing.T) {
	t.Setenv("ENRICH_TEST_KEY", "test-key")
	h := newEnrichHarness(t, manifest{
		Revision: "rev0",
		Requests: []prose.Request{routeReq(), labelReq(), nodeReq()},
		Fresh:    7,
	})
	api := newFakeAPI(t, func(_ int, req apiRequest) (int, string) {
		return http.StatusOK, answerFor(req)
	})
	h.s.endpoint = api.URL

	if err := run(h.s); err != nil {
		t.Fatalf("enrich: %v", err)
	}

	file := h.prose(t)
	if len(file.Entries) != 3 {
		t.Fatalf("wrote %d entries, want 3: %v", len(file.Entries), file.Keys())
	}
	desc, details, ok := file.Route("GET /v1/aliases")
	if !ok || !strings.HasPrefix(desc, "Returns the alias table") || details == "" {
		t.Errorf("route entry = %q / %q (ok=%v)", desc, details, ok)
	}
	if got, ok := file.Label("mem.cache"); !ok || got != "Alias cache" {
		t.Errorf("label = %q (ok=%v); a fenced reply must be accepted", got, ok)
	}
	if _, ok := file.Docs("mem.cache"); !ok {
		t.Error("node docs are incomplete, so the map would not publish them")
	}
	// The hash and the model come from the manifest and the flag, not the model:
	// they are what makes a stale entry detectable and a bad batch findable.
	entry := file.Entries[prose.RouteKey("GET /v1/aliases")]
	if entry.Hash != routeReq().Hash {
		t.Errorf("entry hash = %q, want the manifest's %q", entry.Hash, routeReq().Hash)
	}
	if entry.Model != "claude-test-5" {
		t.Errorf("entry model = %q", entry.Model)
	}

	// What the model was told: the derived facts, the cited source, and a
	// hand-written entry of the same kind to imitate.
	var routePrompt string
	for _, call := range api.prompts() {
		if strings.Contains(call.Messages[0].Content, `kind "route"`) {
			routePrompt = call.Messages[0].Content
		}
		if call.Model != "claude-test-5" {
			t.Errorf("called model %q", call.Model)
		}
		if !strings.Contains(call.System, "Say only what the supplied facts") {
			t.Error("system prompt does not carry the grounding rule")
		}
	}
	if routePrompt == "" {
		t.Fatal("no route prompt was sent")
	}
	for _, want := range []string{
		"handleAliases",              // the facts
		"mem.cache W",                // the derived dependency, with its mode
		"aliases are read through",   // the cited source
		"Returns the models the fle", // the hand-written example
	} {
		if !strings.Contains(routePrompt, want) {
			t.Errorf("route prompt does not carry %q", want)
		}
	}
}

// TestEnrichRejectsInventedState is the property that makes generated prose worth
// committing: a sentence that names state the extractor did not find is sent back
// with the reason, not written to the file.
func TestEnrichRejectsInventedState(t *testing.T) {
	t.Setenv("ENRICH_TEST_KEY", "test-key")
	h := newEnrichHarness(t, manifest{Requests: []prose.Request{routeReq()}})
	h.s.workers = 1

	api := newFakeAPI(t, func(call int, req apiRequest) (int, string) {
		if call == 0 {
			// Fluent, plausible, and false: pg.payouts is in no fact of this request.
			return http.StatusOK, `{"description": "Returns the alias table and settles pg.payouts for the account."}`
		}
		return http.StatusOK, `{"description": "Returns the alias table for the calling account."}`
	})
	h.s.endpoint = api.URL

	if err := run(h.s); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	desc, _, _ := h.prose(t).Route("GET /v1/aliases")
	if strings.Contains(desc, "pg.payouts") {
		t.Fatalf("prose naming state the map never derived was written: %q", desc)
	}
	calls := api.prompts()
	if len(calls) != 2 {
		t.Fatalf("made %d calls, want a rejection and a retry", len(calls))
	}
	retry := calls[1].Messages
	if len(retry) != 3 {
		t.Fatalf("retry turns = %d, want the prompt, the rejected answer and the reason", len(retry))
	}
	if !strings.Contains(retry[2].Content, "pg.payouts") {
		t.Errorf("the rejection does not name what was wrong: %q", retry[2].Content)
	}
}

func TestEnrichRejectsIncompleteNodeDocs(t *testing.T) {
	t.Setenv("ENRICH_TEST_KEY", "test-key")
	h := newEnrichHarness(t, manifest{Requests: []prose.Request{nodeReq()}})
	h.s.workers, h.s.attempts = 1, 2

	api := newFakeAPI(t, func(call int, req apiRequest) (int, string) {
		if call == 0 {
			// Five of eight fields: reads as documentation, is not.
			return http.StatusOK, `{"overview": "The alias cache.", "represents": "One alias.", "construction": "Filled per request.", "access": "Written by the consumer API.", "concurrency": "Guarded per request."}`
		}
		return http.StatusOK, answerFor(req)
	})
	h.s.endpoint = api.URL

	if err := run(h.s); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	if _, ok := h.prose(t).Docs("mem.cache"); !ok {
		t.Error("the corrected answer was not written")
	}
	calls := api.prompts()
	if len(calls) != 2 || !strings.Contains(calls[1].Messages[2].Content, "lifecycle") {
		t.Errorf("the rejection does not name the missing field: %v", calls[1].Messages)
	}
}

// A transient failure is a retry, and a persistent one is a reported failure that
// does not take the successful entries down with it.
func TestEnrichRetriesAndReportsPartialFailure(t *testing.T) {
	t.Setenv("ENRICH_TEST_KEY", "test-key")
	h := newEnrichHarness(t, manifest{Requests: []prose.Request{routeReq(), labelReq()}})
	h.s.workers, h.s.attempts = 1, 2

	api := newFakeAPI(t, func(_ int, req apiRequest) (int, string) {
		prompt := req.Messages[0].Content
		if strings.Contains(prompt, `kind "label"`) {
			return http.StatusServiceUnavailable, `{"error": {"type": "overloaded_error", "message": "overloaded"}}`
		}
		return http.StatusOK, answerFor(req)
	})
	h.s.endpoint = api.URL

	err := run(h.s)
	if err == nil {
		t.Fatal("a failed entry did not fail the run")
	}
	if !strings.Contains(err.Error(), "label:mem.cache") {
		t.Errorf("error does not say which entry failed: %v", err)
	}
	file := h.prose(t)
	if _, _, ok := file.Route("GET /v1/aliases"); !ok {
		t.Error("a failure discarded the entry that succeeded")
	}
	if n := len(api.prompts()); n != 3 {
		t.Errorf("made %d calls, want 1 route + 2 label attempts", n)
	}
}

// Pruning is bookkeeping, not writing: it must work with no key and no network,
// because a pull request that deletes a route has nothing to generate.
func TestEnrichPrunesWithoutAModel(t *testing.T) {
	h := newEnrichHarness(t, manifest{Prune: []string{prose.RouteKey("DELETE /v1/gone")}, Fresh: 4})
	h.s.endpoint = "http://127.0.0.1:1" // any call would fail
	stale := &prose.File{Entries: map[string]prose.Entry{
		prose.RouteKey("DELETE /v1/gone"): {Kind: "route", Hash: "dead", Description: "Removes a thing."},
		prose.RouteKey("GET /v1/kept"):    {Kind: "route", Hash: "beef", Description: "Keeps a thing."},
	}}
	if err := stale.Save(filepath.Join(h.dir, h.s.prosePath)); err != nil {
		t.Fatal(err)
	}

	if err := run(h.s); err != nil {
		t.Fatalf("enrich: %v", err)
	}
	file := h.prose(t)
	if _, ok := file.Entries[prose.RouteKey("DELETE /v1/gone")]; ok {
		t.Error("prose for a route the map no longer has was kept")
	}
	if _, ok := file.Entries[prose.RouteKey("GET /v1/kept")]; !ok {
		t.Error("pruning removed an entry the map still has")
	}
}

// A fork's pull request has no secret, by design. The failure has to say that,
// because otherwise the CI log reads as a broken pipeline rather than as the
// intended fallback.
func TestEnrichWithoutKeyExplainsTheFork(t *testing.T) {
	t.Setenv("ENRICH_TEST_KEY", "")
	h := newEnrichHarness(t, manifest{Requests: []prose.Request{routeReq()}})
	err := run(h.s)
	if err == nil {
		t.Fatal("ran with no API key")
	}
	if !strings.Contains(err.Error(), "fork") || !strings.Contains(err.Error(), "ENRICH_TEST_KEY") {
		t.Errorf("error does not explain the fork fallback: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(h.dir, h.s.prosePath)); statErr == nil {
		t.Error("a run that wrote nothing still created the prose file")
	}
}

func TestEnrichDryRunCallsNothing(t *testing.T) {
	t.Setenv("ENRICH_TEST_KEY", "test-key")
	h := newEnrichHarness(t, manifest{Requests: []prose.Request{routeReq(), nodeReq()}})
	api := newFakeAPI(t, func(_ int, _ apiRequest) (int, string) {
		t.Error("dry run called the model")
		return http.StatusOK, "{}"
	})
	h.s.endpoint, h.s.dryRun = api.URL, true
	if err := run(h.s); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(h.dir, h.s.prosePath)); err == nil {
		t.Error("dry run wrote the prose file")
	}
}

// The guard has to catch a claim about state without firing on the file names,
// hosts and qualified symbols that correct prose is full of — a guard that rejects
// accurate sentences gets its retries burned and fails the run.
func TestSuspectIDsBoundaries(t *testing.T) {
	for _, tc := range []struct {
		text string
		want []string
	}{
		{"Reads the alias map and writes mem.cache.", []string{"mem.cache"}},
		{"Settles pg.payouts, then pg.api_keys for the account.", []string{"pg.payouts", "pg.api_keys"}},
		{"Defined in coordinator/api/server.go and api/consumer.go.", nil},
		{"Fetches manifests from models.darkbloom.ai over TLS.", nil},
		{"The field is api:Server.cache, held per process.", nil},
		{"Providers below v0.6.3 are not routed tool calls.", nil},
		{"Two forms, i.e. one per lane.", nil},
		{"See docs/reference/api-map/overlay.json for the curated half.", nil},
	} {
		got := suspectIDs(tc.text)
		if len(got) != len(tc.want) {
			t.Errorf("suspectIDs(%q) = %v, want %v", tc.text, got, tc.want)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("suspectIDs(%q) = %v, want %v", tc.text, got, tc.want)
				break
			}
		}
	}
}

// The prompt for a regeneration carries the text it replaces, so the model can
// keep the half of a description that is still true.
func TestEnrichCarriesPriorText(t *testing.T) {
	t.Setenv("ENRICH_TEST_KEY", "test-key")
	req := routeReq()
	req.Prior = map[string]string{"description": "Returns the alias table for the calling account."}
	h := newEnrichHarness(t, manifest{Requests: []prose.Request{req}})
	h.s.workers = 1
	api := newFakeAPI(t, func(_ int, r apiRequest) (int, string) { return http.StatusOK, answerFor(r) })
	h.s.endpoint = api.URL

	if err := run(h.s); err != nil {
		t.Fatal(err)
	}
	prompt := api.prompts()[0].Messages[0].Content
	if !strings.Contains(prompt, "facts that have since changed") || !strings.Contains(prompt, req.Prior["description"]) {
		t.Errorf("regeneration prompt does not carry the prior text: %q", prompt)
	}
}
