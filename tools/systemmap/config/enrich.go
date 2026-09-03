package config

import (
	"encoding/json"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/prose"
)

// HumanProse records which prose keys a person wrote, captured before any
// generated prose is merged in. Enrichment is not allowed to write these, and
// the generated file is not allowed to keep a copy of one: a key with two
// answers is a key whose page content depends on load order.
func (c *Config) HumanProse() prose.Existing {
	have := prose.Existing{
		Routes: map[string]bool{},
		Labels: map[string]bool{},
		Docs:   map[string]bool{},
	}
	for key, overlay := range c.Routes {
		if strings.TrimSpace(overlay.Description) != "" {
			have.Routes[key] = true
		}
	}
	for id, label := range c.Labels {
		if strings.TrimSpace(label) != "" {
			have.Labels[id] = true
		}
	}
	for id := range c.DepDocs {
		have.Docs[id] = true
	}
	return have
}

// MergeProse fills the prose gaps in the overlay from the generated file. It
// only ever writes where a person wrote nothing, so the merge is not a source of
// truth conflict: overlay.json wins, always, and deleting a generated entry can
// never delete a hand-written sentence.
//
// A route's `callers` is not merged even when the rest of the entry is
// generated. Who calls an endpoint is a claim about the world outside this
// repository — the console, the provider CLI, infrastructure automation — and
// nothing in the map's derived facts can support or refute it, so a model must
// not assert it. A route with generated prose and no callers renders without a
// caller, which is honest; a route with an invented caller is not.
func (c *Config) MergeProse(f *prose.File) {
	if f == nil {
		return
	}
	if c.Routes == nil {
		c.Routes = map[string]RouteOverlay{}
	}
	for key := range c.routeKeysFrom(f) {
		if strings.TrimSpace(c.Routes[key].Description) != "" {
			continue
		}
		description, details, ok := f.Route(key)
		if !ok {
			continue
		}
		entry := c.Routes[key] // keep hand-written callers on a generated description
		entry.Description, entry.Details = description, details
		c.Routes[key] = entry
	}
	if c.Labels == nil {
		c.Labels = map[string]string{}
	}
	if c.DepDocs == nil {
		c.DepDocs = map[string]json.RawMessage{}
	}
	for _, key := range f.Keys() {
		kind, id, ok := strings.Cut(key, ":")
		if !ok {
			continue
		}
		switch kind {
		case "label":
			if strings.TrimSpace(c.Labels[id]) != "" {
				continue
			}
			if label, ok := f.Label(id); ok {
				c.Labels[id] = label
			}
		case "node":
			if _, ok := c.DepDocs[id]; ok {
				continue
			}
			if docs, ok := f.Docs(id); ok {
				c.DepDocs[id] = docs
			}
		}
	}
}

// routeKeysFrom lists the route keys the generated file carries, so merging does
// not have to iterate the (much larger) set of registered routes.
func (c *Config) routeKeysFrom(f *prose.File) map[string]bool {
	out := map[string]bool{}
	for _, key := range f.Keys() {
		if kind, route, ok := strings.Cut(key, ":"); ok && kind == "route" {
			out[route] = true
		}
	}
	return out
}

// SymbolsByNode reverse-indexes the mapping tables: for each dependency node,
// the source symbols and literals bound to it. Enrichment needs it because a
// node id is not self-explanatory — `mem.chunkKeys` means little, while
// `coordinator/api:Server.chunkKeys` and the type behind it say what the thing
// is. Everything here is already in the overlay; nothing is derived twice.
func (c *Config) SymbolsByNode() map[string][]string {
	out := map[string][]string{}
	add := func(node, symbol string) {
		if node = sentinel(node); node == "" {
			return
		}
		out[node] = append(out[node], symbol)
	}
	for key, node := range c.Deps.Fields {
		add(node, "field "+key)
	}
	for key, node := range c.Deps.Types {
		add(node, "type "+key)
	}
	for key, node := range c.Deps.Functions {
		add(node, "func "+key)
	}
	for host, node := range c.Deps.Hosts {
		add(node, "host "+host)
	}
	for pkg, table := range c.Deps.Endpoints {
		for literal, node := range table {
			add(node, "endpoint "+pkg+" "+literal)
		}
	}
	for pkg, table := range c.Deps.Messages {
		for ident, node := range table {
			add(node, "message "+pkg+" "+ident)
		}
	}
	for node := range out {
		sort.Strings(out[node])
	}
	return out
}
