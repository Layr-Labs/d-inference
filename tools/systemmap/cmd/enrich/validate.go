package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/prose"
)

// Validation is the half of this program that matters. A model writing
// documentation will occasionally write a fluent sentence about a table the code
// does not touch, and prose that names state is exactly the prose a reader trusts
// most. So a completion is checked against the facts it was given before it is
// allowed into the file, and a rejection is fed back as another turn rather than
// dropped — the model is told which rule it broke.
//
// Nothing here can protect the *graph*: generated prose cannot create a node or
// an edge, by construction (see package prose). These checks protect the reader
// of a sentence.

// limits per field. They are generous enough that a correct answer is never
// rejected for length and tight enough that a model cannot pad.
const (
	maxDescription = 240
	maxDetails     = 900
	maxLabel       = 44
	maxDocField    = 460
)

var (
	// A dotted token, whatever it turns out to name. Which of these are node ids is
	// decided by the categories the map actually uses, not by this shape: a single
	// letter is a legal category and a node name can be camelCase, and requiring two
	// leading letters and lower case let both through unchecked.
	idToken = regexp.MustCompile(`[A-Za-z][A-Za-z0-9]*\.[A-Za-z_][A-Za-z0-9_]*`)
	// Markdown the renderer would print literally. `(?m)` because `details` is
	// several lines: anchored to the whole text, a bullet list starting on line two
	// went straight into the page.
	markdown = regexp.MustCompile("(?m)```|\\]\\(|^\\s*[-*]\\s|^#{1,6}\\s")
	banned   = []string{
		"robust", "seamless", "seamlessly", "powerful", "simply", "leverage",
		"appears to", "presumably", "likely", "should be", "we ", "our ",
	}
)

// parseCompletion pulls the JSON object out of a completion. A fence is stripped
// rather than rejected: it is the one deviation models make that carries no risk,
// and burning a retry on it buys nothing.
func parseCompletion(text string) (map[string]string, error) {
	trimmed := strings.TrimSpace(text)
	if fence := strings.Index(trimmed, "```"); fence >= 0 {
		rest := trimmed[fence+3:]
		if nl := strings.IndexByte(rest, '\n'); nl >= 0 {
			rest = rest[nl+1:]
		}
		if end := strings.Index(rest, "```"); end >= 0 {
			rest = rest[:end]
		}
		trimmed = strings.TrimSpace(rest)
	}
	if start := strings.IndexByte(trimmed, '{'); start > 0 {
		trimmed = trimmed[start:]
	}
	var fields map[string]string
	if err := json.Unmarshal([]byte(trimmed), &fields); err != nil {
		return nil, fmt.Errorf("reply is not a JSON object of strings: %v", err)
	}
	return fields, nil
}

// validate turns a completion into an entry, or says why it cannot. The guard is
// shared across the run so a request's own facts are what bound it.
func validate(req prose.Request, fields map[string]string, guard idGuard, model string) (prose.Entry, error) {
	entry := prose.Entry{Kind: req.Kind, Hash: req.Hash, Model: model}
	allowed := allowedFields(req.Kind)
	for name := range fields {
		if !allowed[name] {
			return entry, fmt.Errorf("field %q is not part of a %s entry; write only %s", name, req.Kind, strings.Join(sortedSet(allowed), ", "))
		}
	}

	check := func(name, text string, max int, oneLine bool) error {
		text = strings.TrimSpace(text)
		if len(text) > max {
			return fmt.Errorf("%q is %d characters, the limit is %d", name, len(text), max)
		}
		if oneLine && strings.ContainsAny(text, "\n\r") {
			return fmt.Errorf("%q must be a single line", name)
		}
		if markdown.MatchString(text) {
			return fmt.Errorf("%q contains markdown; write plain prose (backticks around an identifier are fine)", name)
		}
		for _, word := range banned {
			if strings.Contains(strings.ToLower(text), word) {
				return fmt.Errorf("%q contains %q, which this documentation does not use", name, strings.TrimSpace(word))
			}
		}
		return guard.check(name, text, req)
	}

	switch req.Kind {
	case "route":
		desc := strings.TrimSpace(fields["description"])
		if desc == "" {
			return entry, fmt.Errorf("%q is required", "description")
		}
		if err := check("description", desc, maxDescription, true); err != nil {
			return entry, err
		}
		if err := check("details", fields["details"], maxDetails, false); err != nil {
			return entry, err
		}
		entry.Description, entry.Details = desc, strings.TrimSpace(fields["details"])
	case "label":
		label := strings.TrimSpace(fields["label"])
		if label == "" {
			return entry, fmt.Errorf("%q is required", "label")
		}
		if err := check("label", label, maxLabel, true); err != nil {
			return entry, err
		}
		if strings.HasSuffix(label, ".") {
			return entry, fmt.Errorf("%q is a name, not a sentence; drop the trailing period", "label")
		}
		entry.Label = label
	case "node":
		entry.Docs = map[string]string{}
		for _, field := range prose.DocFields {
			text := strings.TrimSpace(fields[field])
			if text == "" {
				return entry, fmt.Errorf("%q is empty; a node documented in some fields reads as complete and is not", field)
			}
			if err := check(field, text, maxDocField, false); err != nil {
				return entry, err
			}
			entry.Docs[field] = text
		}
	default:
		return entry, fmt.Errorf("unknown kind %q", req.Kind)
	}
	return entry, nil
}

func allowedFields(kind string) map[string]bool {
	out := map[string]bool{}
	switch kind {
	case "route":
		out["description"], out["details"] = true, true
	case "label":
		out["label"] = true
	case "node":
		for _, f := range prose.DocFields {
			out[f] = true
		}
	}
	return out
}

// idGuard rejects prose that names state the request's facts do not contain.
//
// A model writing about a control plane will occasionally produce a fluent
// sentence about `pg.payouts` for an endpoint that never touches it, and a claim
// shaped like a node id is the claim a reader trusts most. So a token that names a
// node must appear in the facts that request was given.
//
// What counts as naming a node is decided by the map, not by the token's shape.
// The manifest carries the map's whole vocabulary of state — every node-id category
// it draws and every table it derived — and a dotted token is only held to the facts
// when its category is one of them. Guessing from the shape instead was wrong in
// both directions at once, which is the worst way to be wrong about a guard: it
// fired on prose that names no state at all (`response.created`, `usage.total_tokens`,
// an SSE event or a JSON field) and it let through everything the shape did not
// cover (a single-letter category, a camelCase field), so the sentences it rejected
// were correct and the sentences it was built to catch got through.
//
// The vocabulary comes from the map rather than from the plan's own requests for the
// same reason: a plan is usually one or two entries, and a guard that only knows the
// state those entries touch cannot tell that `pg.payouts` is state at all — the
// invented-table sentence would be accepted precisely when the plan was small.
//
// Bare table names are held to the facts too, but only where the prose says the
// word "table" beside them: `pg.payouts` is unmistakable, "the payouts table" is
// the same claim, and "the models a provider serves" is ordinary English about a
// table that happens to be called `models`. Requiring the word is what separates
// them.
type idGuard struct {
	categories map[string]bool // node-id categories this map uses: pg, mem, ext, …
	tables     map[string]bool // pg.* names, for the bare-name rule
}

// newIDGuard takes what a node id looks like in this map from the manifest.
func newIDGuard(plan manifest) idGuard {
	g := idGuard{categories: map[string]bool{}, tables: map[string]bool{}}
	for _, c := range plan.Categories {
		if c != "" {
			g.categories[strings.ToLower(c)] = true
		}
	}
	for _, t := range plan.Tables {
		if t != "" {
			g.tables[strings.ToLower(t)] = true
		}
	}
	return g
}

func (g idGuard) check(field, text string, req prose.Request) error {
	facts := mustJSON(req.Facts) + " " + req.Key
	for _, id := range idToken.FindAllString(text, -1) {
		category, _, _ := strings.Cut(id, ".")
		if !g.categories[strings.ToLower(category)] {
			continue // not a node id in this map: a file, a host, a JSON field, a symbol
		}
		if strings.Contains(facts, id) || strings.Contains(strings.ToLower(facts), strings.ToLower(id)) {
			continue
		}
		return fmt.Errorf("%q names %s, which is not in the derived facts for this entry; describe only the state listed there", field, id)
	}
	for _, table := range g.namedTables(text) {
		if strings.Contains(strings.ToLower(facts), "pg."+table) {
			continue
		}
		return fmt.Errorf("%q calls %s a table, but this entry's derived facts do not touch pg.%s; describe only the state listed there", field, table, table)
	}
	return nil
}

// namedTables returns the table names the text calls tables.
func (g idGuard) namedTables(text string) []string {
	lower := strings.ToLower(text)
	var out []string
	for _, m := range tablePhrase.FindAllStringSubmatch(lower, -1) {
		for _, word := range m[1:] {
			if word != "" && g.tables[word] {
				out = append(out, word)
			}
		}
	}
	return out
}

// tablePhrase matches a table named as one: "the payouts table", "table payouts".
var tablePhrase = regexp.MustCompile(`\b([a-z][a-z0-9_]*)\s+table\b|\btable\s+([a-z][a-z0-9_]*)\b`)

func sortedSet(in map[string]bool) []string {
	out := make([]string, 0, len(in))
	for k := range in {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
