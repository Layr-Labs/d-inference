package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/prose"
)

// The prose enrichment loop, run end to end against the fixture service: the
// gate names what is missing, the manifest says which facts it must be written
// from, filling it in satisfies the gate, and changing the facts under a
// generated sentence turns it back into drift.
//
// That last property is the whole point of generating prose rather than writing
// it. A hand-written description is checked for presence and never for truth, so
// it survives every change to the route it describes. A generated one carries the
// hash of the facts it was written from, so it does not.

// proseHarness is a throwaway copy of the fixture overlay with some prose
// removed, plus the temp paths a run writes to. Nothing here touches the
// repository: the overlay copy, the generated prose and the map all live in the
// test's own directory, and only `-root` still points at the fixture source.
type proseHarness struct {
	opt      options
	dir      string
	prosePth string
	manifest string
}

func newProseHarness(t *testing.T, edit func(overlay map[string]any)) proseHarness {
	t.Helper()
	root, err := filepath.Abs("testdata/fixture")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "overlay.json"))
	if err != nil {
		t.Fatal(err)
	}
	var overlay map[string]any
	if err := json.Unmarshal(raw, &overlay); err != nil {
		t.Fatal(err)
	}
	edit(overlay)
	edited, err := json.Marshal(overlay)
	if err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "overlay.json"), edited, 0o644); err != nil {
		t.Fatal(err)
	}
	// Every path a run takes is relative to -root, so the hop from the fixture to
	// the temp directory is how a throwaway location is expressed.
	rel, err := filepath.Rel(root, dir)
	if err != nil {
		t.Fatal(err)
	}
	return proseHarness{
		opt: options{
			Root: root, Module: "svcfix.test",
			Overlay:  filepath.Join(rel, "overlay.json"),
			Prose:    filepath.Join(rel, "prose.json"),
			Out:      rel,
			Manifest: filepath.Join(rel, "plan.json"),
			Revision: fixtureRevision, Check: true, Quiet: true,
		},
		dir:      dir,
		prosePth: filepath.Join(dir, "prose.json"),
		manifest: filepath.Join(dir, "plan.json"),
	}
}

type manifest struct {
	Revision string          `json:"revision"`
	Requests []prose.Request `json:"requests"`
	Prune    []string        `json:"prune"`
	Fresh    int             `json:"fresh"`
}

func (h proseHarness) run(t *testing.T) (manifest, error) {
	t.Helper()
	err := run(h.opt)
	raw, readErr := os.ReadFile(h.manifest)
	if readErr != nil {
		t.Fatalf("no manifest written: %v (run error: %v)", readErr, err)
	}
	var m manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	return m, err
}

func (h proseHarness) writeProse(t *testing.T, f *prose.File) {
	t.Helper()
	if err := f.Save(h.prosePth); err != nil {
		t.Fatal(err)
	}
}

// answer fills a request the way a well-behaved enricher would, so the test
// exercises the plumbing rather than a model.
func answer(req prose.Request) prose.Entry {
	e := prose.Entry{Kind: req.Kind, Hash: req.Hash, Model: "test"}
	switch req.Kind {
	case "route":
		e.Description = "Generated description of " + req.Key + "."
	case "label":
		e.Label = "Generated " + req.Key
	case "node":
		e.Docs = map[string]string{}
		for _, field := range prose.DocFields {
			e.Docs[field] = "Generated " + field + " for " + req.Key + "."
		}
	}
	return e
}

func TestProseEnrichmentLoop(t *testing.T) {
	if testing.Short() {
		t.Skip("type-checks the fixture service")
	}
	const route = "GET /v1/aliases"
	h := newProseHarness(t, func(overlay map[string]any) {
		delete(overlay["routes"].(map[string]any), route)
		delete(overlay["labels"].(map[string]any), "mem.cache")
		delete(overlay["depDocs"].(map[string]any), "mem.cache")
	})

	// 1. The gate fails and the manifest says exactly what to write, for which
	//    key, from which facts.
	plan, err := h.run(t)
	if err == nil {
		t.Fatal("a route with no prose, an unlabeled node and an undocumented node did not fail -check")
	}
	byKey := map[string]prose.Request{}
	for _, req := range plan.Requests {
		byKey[req.Kind+":"+req.Key] = req
	}
	for _, want := range []string{"route:" + route, "label:mem.cache", "node:mem.cache"} {
		if _, ok := byKey[want]; !ok {
			t.Fatalf("manifest has no request for %s; got %v", want, plan.Requests)
		}
	}
	if plan.Fresh != 0 || len(plan.Prune) != 0 {
		t.Errorf("plan = %d fresh, %d prune on a first run, want none", plan.Fresh, len(plan.Prune))
	}

	// The route request carries the derived facts and nothing else: enrichment
	// must not be able to justify a sentence with something the map did not find.
	req := byKey["route:"+route]
	if got := req.Facts["handler"]; got != "handleAliases" {
		t.Errorf("route facts handler = %v, want handleAliases", got)
	}
	deps, _ := json.Marshal(req.Facts["dependencies"])
	if want := `["mem.aliases R","mem.cache W","mem.flight RW"]`; string(deps) != want {
		t.Errorf("route facts dependencies = %s, want %s", deps, want)
	}
	if req.Cite == "" {
		t.Error("route request cites no source, so an enricher cannot read the handler")
	}
	if req.Prior != nil {
		t.Errorf("first request carries prior text %v", req.Prior)
	}

	// 2. Filling the requests satisfies the gate, and the generated sentence is
	//    what the map publishes.
	file := &prose.File{Entries: map[string]prose.Entry{}}
	for _, req := range plan.Requests {
		file.Entries[req.Kind+":"+req.Key] = answer(req)
	}
	h.writeProse(t, file)

	plan, err = h.run(t)
	if err != nil {
		t.Fatalf("generated prose did not satisfy the gate: %v", err)
	}
	if len(plan.Requests) != 0 || plan.Fresh != 3 {
		t.Errorf("plan = %d requests, %d fresh after filling all three, want 0 and 3", len(plan.Requests), plan.Fresh)
	}
	h.opt.Check = false
	if _, err := h.run(t); err != nil {
		t.Fatalf("generate failed with generated prose: %v", err)
	}
	inventory := map[string]any{}
	raw, err := os.ReadFile(filepath.Join(h.dir, "inventory.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &inventory); err != nil {
		t.Fatal(err)
	}
	if got := routeDescription(t, inventory, route); got != "Generated description of "+route+"." {
		t.Errorf("published description = %q, want the generated one", got)
	}
	h.opt.Check = true

	// 3. Change a fact under the sentence and it becomes drift. The overlay's auth
	//    rule is what changes here, which is a fact the description was written
	//    from and the kind of change that makes prose quietly wrong.
	stale := *file
	entry := stale.Entries["route:"+route]
	entry.Hash = "0000000000000000000000000000"
	stale.Entries["route:"+route] = entry
	h.writeProse(t, &stale)

	plan, err = h.run(t)
	if err == nil {
		t.Fatal("prose written from facts that no longer hold did not fail -check")
	}
	if !strings.Contains(err.Error(), "outdated generated prose") {
		t.Errorf("error = %v, want it to count outdated generated prose", err)
	}
	if len(plan.Requests) != 1 || plan.Requests[0].Key != route {
		t.Fatalf("plan = %v, want one request for the stale route", plan.Requests)
	}
	if plan.Requests[0].Prior["description"] == "" {
		t.Error("a regeneration request does not carry the text it replaces")
	}
}

// TestProseHumanWins is the property that makes generated prose safe to commit:
// a person's sentence is never overwritten, never merged over, and the generated
// copy is retired rather than kept as a second answer.
func TestProseHumanWins(t *testing.T) {
	if testing.Short() {
		t.Skip("type-checks the fixture service")
	}
	const route = "GET /v1/aliases"
	h := newProseHarness(t, func(overlay map[string]any) {})
	h.writeProse(t, &prose.File{Entries: map[string]prose.Entry{
		prose.RouteKey(route): {Kind: "route", Hash: "deadbeefdeadbeefdeadbeef", Description: "Generated text."},
	}})

	plan, err := h.run(t)
	if err != nil {
		t.Fatalf("a generated entry for a hand-written route caused drift: %v", err)
	}
	if len(plan.Prune) != 1 || plan.Prune[0] != prose.RouteKey(route) {
		t.Errorf("plan prune = %v, want the superseded entry", plan.Prune)
	}
	if len(plan.Requests) != 0 {
		t.Errorf("plan asks to rewrite prose a person already wrote: %v", plan.Requests)
	}

	h.opt.Check = false
	if _, err := h.run(t); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(h.dir, "inventory.json"))
	if err != nil {
		t.Fatal(err)
	}
	inventory := map[string]any{}
	if err := json.Unmarshal(raw, &inventory); err != nil {
		t.Fatal(err)
	}
	if got := routeDescription(t, inventory, route); got == "Generated text." {
		t.Error("generated prose overwrote a hand-written description")
	}
}

// TestProseLabelFactsIgnoreUse pins the reason a label and a node's docs are
// hashed over different facts. A label is a name: it must not be rewritten
// because another endpoint started touching the node. Documentation is about
// use, so it must be.
func TestProseLabelFactsIgnoreUse(t *testing.T) {
	if testing.Short() {
		t.Skip("type-checks the fixture service")
	}
	base, _, cfg := buildFixtureCfg(t)
	symbols := cfg.SymbolsByNode()
	empty := &prose.File{Entries: map[string]prose.Entry{}}

	// Drop every hand-written label and doc so both kinds are planned, then take
	// the same node's requests before and after an endpoint stops touching it.
	bare := func(g *ir.Graph) map[string]prose.Request {
		out := map[string]prose.Request{}
		for _, req := range prose.Build(g, prose.Existing{}, symbols, empty).Requests {
			out[req.Kind+":"+req.Key] = req
		}
		return out
	}
	before := bare(base)

	narrowed, _, _ := buildFixtureCfg(t, func(c *config.Config) {
		// A namespace rename changes which namespaces reach every node, which is a
		// fact about use and not about identity.
		c.Namespaces = append([]config.NamespaceRule{{Prefix: "/v1/aliases", Namespace: "Renamed"}}, c.Namespaces...)
	})
	after := bare(narrowed)

	const node = "mem.cache"
	if before["label:"+node].Hash != after["label:"+node].Hash {
		t.Errorf("label hash moved when only the calling namespace changed: %s → %s",
			before["label:"+node].Hash, after["label:"+node].Hash)
	}
	if before["node:"+node].Hash == after["node:"+node].Hash {
		t.Error("node documentation hash did not move when the namespaces reaching it changed")
	}
}

func routeDescription(t *testing.T, inventory map[string]any, key string) string {
	t.Helper()
	routes, ok := inventory["routes"].([]any)
	if !ok {
		t.Fatal("inventory has no routes")
	}
	for _, entry := range routes {
		r := entry.(map[string]any)
		if r["method"].(string)+" "+r["path"].(string) == key {
			desc, _ := r["description"].(string)
			return desc
		}
	}
	t.Fatalf("route %q not in inventory", key)
	return ""
}
