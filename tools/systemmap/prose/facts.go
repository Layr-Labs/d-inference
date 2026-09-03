package prose

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// Request is one piece of prose that needs writing, together with every derived
// fact it may be written from. The facts are the whole input: an enricher is not
// allowed to consult anything the map did not derive, because prose justified by
// something outside the map cannot be checked against the map.
type Request struct {
	Key   string            `json:"key"`
	Kind  string            `json:"kind"`
	Hash  string            `json:"hash"`
	Facts map[string]any    `json:"facts"`
	Cite  string            `json:"cite,omitempty"`  // file:line of the code being described
	Prior map[string]string `json:"prior,omitempty"` // the entry being replaced, when one exists
}

// Plan is everything enrichment should do to the generated file for one map.
type Plan struct {
	Requests []Request // prose that is missing, or whose source has moved
	Prune    []string  // entries for a key the map no longer has, or a person now covers
	Fresh    int       // entries whose hash still matches, and which cost nothing
}

// Existing is the prose a person has written by hand, which enrichment must
// never overwrite and never duplicate.
type Existing struct {
	Routes map[string]bool
	Labels map[string]bool
	Docs   map[string]bool
}

// Build works out what needs writing. A request is produced when a key has no
// prose at all, or when its generated prose was written from facts that have
// since changed — the second case being the whole reason the hash is stored.
// Neither depends on the model or on the network, so `-check` can report exactly
// what CI will do without an API key.
func Build(g *ir.Graph, human Existing, symbols map[string][]string, have *File) Plan {
	var plan Plan
	live := map[string]bool{}

	consider := func(key, kind, cite string, facts map[string]any, humanHas bool) {
		full := kind + ":" + key
		if humanHas {
			return // a person said it; the generated file has no business here
		}
		live[full] = true
		hash := hashFacts(kind, key, facts)
		if e, ok := have.Entries[full]; ok && e.Hash == hash && filled(kind, e) {
			plan.Fresh++
			return
		}
		req := Request{Key: key, Kind: kind, Hash: hash, Facts: facts, Cite: cite}
		if e, ok := have.Entries[full]; ok {
			req.Prior = priorText(e)
		}
		plan.Requests = append(plan.Requests, req)
	}

	for _, ep := range g.Routes {
		key := ep.Method + " " + ep.Path
		consider(key, "route", ep.Source, routeFacts(ep), human.Routes[key])
	}
	for _, id := range sortedKeys(g.Nodes) {
		node := g.Nodes[id]
		if !node.Reached {
			// A node no endpoint reaches is declared but not drawn into the story the
			// map tells; the report already says so, and inventing prose for it would
			// describe something the reader cannot get to.
			continue
		}
		// A node needs a curated label when source cannot name it on its own — a
		// `pg.*` node is its table, everything else has to be named. The third
		// clause is what keeps an already-generated label under the hash check:
		// by the time this runs the generated label has been merged in, so the
		// node no longer looks unnamed.
		if node.Label == "" || node.Label == id || have.Entries[LabelKey(id)].Label != "" {
			consider(id, "label", "", labelFacts(node, symbols[id]), human.Labels[id])
		}
		consider(id, "node", "", nodeFacts(g, node, symbols[id]), human.Docs[id])
	}

	for _, key := range have.Keys() {
		if !live[key] {
			plan.Prune = append(plan.Prune, key)
		}
	}
	return plan
}

// filled reports whether an entry actually carries the prose its kind promises.
// An entry with a current hash and an empty description is not fresh; it is a
// generation that failed and must be retried rather than trusted.
func filled(kind string, e Entry) bool {
	switch kind {
	case "route":
		return strings.TrimSpace(e.Description) != ""
	case "label":
		return strings.TrimSpace(e.Label) != ""
	case "node":
		for _, f := range DocFields {
			if strings.TrimSpace(e.Docs[f]) == "" {
				return false
			}
		}
		return true
	}
	return false
}

func priorText(e Entry) map[string]string {
	out := map[string]string{}
	if e.Description != "" {
		out["description"] = e.Description
	}
	if e.Details != "" {
		out["details"] = e.Details
	}
	if e.Label != "" {
		out["label"] = e.Label
	}
	for k, v := range e.Docs {
		out[k] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// routeFacts is what the map knows about one endpoint. Every field here is
// derived: the method and path come from the route table, the middleware chain
// and gates from the handler's reachable code, the dependencies from the state
// that code touches and whether it read or wrote it.
//
// The handler's body is deliberately not hashed. Hashing it would regenerate
// every route's prose on any edit inside its handler, including edits that
// change nothing a reader of the map can see; these facts move exactly when the
// map's own picture of the route moves. The cost is a body change that alters no
// gate, no auth class and no state access, which the prose usually did not
// mention either — see the README's amber-tier note.
func routeFacts(ep *ir.Endpoint) map[string]any {
	deps := make([]string, 0, len(ep.Dependencies))
	for _, dep := range ep.Dependencies {
		deps = append(deps, dep+" "+ep.DepModes[dep])
	}
	sort.Strings(deps)
	return map[string]any{
		"method":       ep.Method,
		"path":         ep.Path,
		"handler":      ep.Handler,
		"namespace":    ep.Namespace,
		"auth":         ep.Auth,
		"authDetail":   ep.AuthDetail,
		"middleware":   strList(ep.Middleware),
		"gates":        strList(ep.Gates),
		"dependencies": deps,
	}
}

// labelFacts is what a node's *name* may be derived from: its identity, not its
// use. A label must not move because another endpoint started touching the node,
// so the routes are not in here.
func labelFacts(node *ir.Node, symbols []string) map[string]any {
	return map[string]any{
		"id":       node.ID,
		"category": node.Category,
		"namedBy":  strList(node.NamedBy),
		"symbols":  strList(symbols),
	}
}

// nodeFacts is what the map knows about one dependency node: what names it, what
// its shape is if source declares one, and which namespaces reach it in which
// mode. Unlike a label, documentation is about use, so the access pattern is
// part of it and prose is rewritten when that pattern changes.
func nodeFacts(g *ir.Graph, node *ir.Node, symbols []string) map[string]any {
	facts := map[string]any{
		"id":       node.ID,
		"category": node.Category,
		"namedBy":  strList(node.NamedBy),
		"symbols":  strList(symbols),
	}
	access := map[string]bool{}
	for _, edge := range g.StateAccess {
		if edge.Dependency == node.ID {
			access[edge.Namespace+" "+edge.Mode] = true
		}
	}
	facts["access"] = sortedSet(access)
	if table, ok := g.Tables[strings.TrimPrefix(node.ID, "pg.")]; ok && strings.HasPrefix(node.ID, "pg.") {
		cols := make([]string, 0, len(table.Columns))
		for _, c := range table.Columns {
			cols = append(cols, c.Name+" "+c.Type)
		}
		sort.Strings(cols)
		facts["columns"] = cols
		constraints := make([]string, 0, len(table.Constraints))
		for _, c := range table.Constraints {
			constraints = append(constraints, fmt.Sprint(c))
		}
		sort.Strings(constraints)
		facts["constraints"] = constraints
	}
	return facts
}

// hashFacts fingerprints the facts an entry was written from. Marshalling a
// map[string]any sorts the keys, so the digest depends on the facts and not on
// the order they were collected in.
func hashFacts(kind, key string, facts map[string]any) string {
	payload := map[string]any{"v": Version, "kind": kind, "key": key, "facts": facts}
	raw, err := json.Marshal(payload)
	if err != nil {
		// Facts are strings and string slices by construction; a failure here is a
		// programming error, and hashing the error is worse than saying so.
		panic("prose: facts are not marshallable: " + err.Error())
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:12])
}

func strList(in []string) []string {
	if in == nil {
		return []string{}
	}
	return in
}

func sortedSet(in map[string]bool) []string {
	out := make([]string, 0, len(in))
	for k := range in {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
