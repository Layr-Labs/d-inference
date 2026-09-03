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
	// A node id as the map writes it: a category, a dot, a lower-case name.
	idToken = regexp.MustCompile(`[a-z][a-z0-9]+\.[a-z_][a-z0-9_]+`)
	// Markdown the renderer would print literally.
	markdown = regexp.MustCompile("```|\\]\\(|^\\s*[-*]\\s|^#{1,6}\\s")
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
// shaped like a node id is the claim a reader trusts most. So any such token in a
// completion must appear in the facts that request was given.
//
// The narrowing is done by shape rather than by an allowlist of categories,
// because a manifest for a single route would not contain enough categories to
// learn from and a guard that quietly switches itself off is worse than none.
// What is excluded is everything else prose legitimately writes with a dot: a file
// name (`server.go`), a hostname (`api.darkbloom.dev`), a path or a qualified
// symbol — all recognised by the characters around the token rather than by a
// list of words.
type idGuard struct{}

func (idGuard) check(field, text string, req prose.Request) error {
	facts := mustJSON(req.Facts) + " " + req.Key
	for _, id := range suspectIDs(text) {
		if !strings.Contains(facts, id) {
			return fmt.Errorf("%q names %s, which is not in the derived facts for this entry; describe only the state listed there", field, id)
		}
	}
	return nil
}

// suspectIDs returns the tokens in a completion that claim to be map nodes.
//
// A node id stands alone: two dotted lower-case segments with ordinary prose on
// either side. A third segment (`api.darkbloom.dev`), a path separator
// (`coordinator/api/server.go`) or a qualifier (`api:Server.cache`) all mean the
// token is naming something else, so the characters bounding the match are what
// decides, and a file extension is excluded outright.
func suspectIDs(text string) []string {
	var out []string
	for _, span := range idToken.FindAllStringIndex(text, -1) {
		start, end := span[0], span[1]
		// Anything joined to the left means the match is a tail of something else:
		// `Server.cache` matches from "erver", `api/consumer` from "consumer".
		if start > 0 && (isWordish(text[start-1]) || strings.ContainsRune("./:-@", rune(text[start-1]))) {
			continue
		}
		if end < len(text) {
			next := text[end]
			// A third segment makes it a host or a path, not a node id. A bare
			// sentence-ending period does not, which is where most node ids sit.
			if next == '.' && end+1 < len(text) && isWordish(text[end+1]) {
				continue
			}
			if isWordish(next) || strings.ContainsRune("/-@", rune(next)) {
				continue
			}
		}
		if _, name, _ := strings.Cut(text[start:end], "."); fileSuffixes[name] {
			continue
		}
		out = append(out, text[start:end])
	}
	return out
}

func isWordish(c byte) bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// fileSuffixes are the tails that make a dotted token a file rather than a node.
// A node's name is a Go field or a table, and none of these are.
var fileSuffixes = map[string]bool{
	"go": true, "json": true, "md": true, "sql": true, "sh": true, "yml": true,
	"yaml": true, "ts": true, "tsx": true, "js": true, "swift": true, "html": true,
	"plist": true, "toml": true, "txt": true, "mobileconfig": true, "metallib": true,
}

func sortedSet(in map[string]bool) []string {
	out := make([]string, 0, len(in))
	for k := range in {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
