package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/prose"
)

// The prompt is built from three things, in descending order of authority:
//
//  1. The derived facts. These are the only grounds a sentence may have. The
//     manifest carries them, the hash covers them, and the validator rejects a
//     completion that names state the facts do not.
//  2. The cited source. A handler's own code is what makes a description say
//     what the endpoint does rather than restate its path. It is context, not
//     licence: it cannot introduce a dependency, because the extractor already
//     derived those and the validator holds the text to them.
//  3. Two hand-written entries of the same kind, as style anchors. The overlay
//     has a hundred of them and they set the register — terse, declarative,
//     present tense, no marketing. Copying that register is most of the work.
const systemPrompt = `You are writing reference documentation for the Darkbloom system map: a
generated architecture map of a Go control plane. Every route and every piece of state on the
map was derived from source by a type-checking extractor. Your job is the prose only.

Rules, in order of importance:

1. Say only what the supplied facts and source support. Do not name a database table, an
   in-memory structure, an external host or an endpoint that is not in the facts. If you are
   unsure whether something is true, leave it out — a shorter sentence is always acceptable.
2. Do not speculate about intent, performance, security posture or roadmap. Describe what the
   code does.
3. No marketing language, no "robust", "seamlessly", "powerful", "simply". No hedging
   ("appears to", "presumably"). Present tense, active voice, declarative.
4. No markdown: no code fences, no bullet lists, no links, no bold. Backticks around an
   identifier are fine and expected.
5. Match the register of the examples exactly. They were written by the engineers who own this
   code.
6. Reply with a single JSON object and nothing else — no preamble, no fence.`

// kindInstruction is the shape and the budget for one kind of entry. The lengths
// are the validator's, stated here so the model aims at them rather than being
// rejected by them.
func kindInstruction(kind string) string {
	switch kind {
	case "route":
		return `Write this JSON object:

{"description": "...", "details": "..."}

"description": one sentence, under 200 characters, saying what this endpoint does. It is the
line a reader sees next to the route in a table, so it must stand alone without the path.
Start with a verb ("Returns ...", "Creates ...", "Accepts ..."). No trailing context.

"details": two to four sentences on how the endpoint behaves: what it reads and writes, what
the authorization gate means for a caller, what the notable failure or status codes are — but
only where the facts or source say so. Omit the field entirely (or leave it empty) if the
facts support nothing beyond the description.`
	case "label":
		return `Write this JSON object:

{"label": "..."}

"label" is the display name for this piece of state on the map: two to four words, Title Case
or the natural casing of the thing named, under 40 characters, no trailing period, no type
suffix like "Map" or "Struct" unless the concept genuinely is one. It names what the state
*is* to a reader ("Warm pool controller", "Chunk key cache"), not where it lives.`
	case "node":
		return `Write this JSON object, with all eight fields present and none empty:

{"overview": "...", "represents": "...", "construction": "...", "access": "...",
 "concurrency": "...", "lifecycle": "...", "restart": "...", "sources": "..."}

  overview      one or two sentences: what this state is and why the system has it.
  represents    what one entry or row means in the domain.
  construction  where it comes from — who allocates or writes it first.
  access        which parts of the system read and write it, from the access facts.
  concurrency   how concurrent access is coordinated, only if the facts or source show it;
                otherwise say what the facts do show ("Guarded per request by the handler").
  lifecycle     how entries are created, updated and removed.
  restart       what survives a coordinator restart and what does not. A Postgres table
                survives; in-process state does not.
  sources       the symbols and files that define it, from the "symbols" fact.

Each field is one to three sentences, under 400 characters.`
	}
	return ""
}

// buildTurns renders one request into the conversation that answers it. Retries
// reuse the turns and append the rejection, so a model that broke a rule is told
// which rule rather than asked again identically.
func buildTurns(req prose.Request, ctx contextSource) []message {
	var b strings.Builder
	fmt.Fprintf(&b, "Write generated prose of kind %q for %q.\n\n", req.Kind, req.Key)
	b.WriteString(kindInstruction(req.Kind))
	b.WriteString("\n\nDerived facts (the only grounds you have):\n\n")
	b.WriteString(mustJSON(req.Facts))
	b.WriteString("\n")

	if src := ctx.source(req.Cite); src != "" {
		fmt.Fprintf(&b, "\nSource at %s, for context only — it cannot add a dependency:\n\n%s\n", req.Cite, src)
	}
	if examples := ctx.examples(req.Kind); examples != "" {
		b.WriteString("\nHand-written entries of this kind, for register:\n\n")
		b.WriteString(examples)
		b.WriteString("\n")
	}
	if len(req.Prior) > 0 {
		b.WriteString("\nThis entry already exists but was written from facts that have since changed. " +
			"Rewrite it against the facts above; keep what is still accurate.\n\n")
		b.WriteString(mustJSON(req.Prior))
		b.WriteString("\n")
	}
	return []message{{Role: "user", Content: b.String()}}
}

// contextSource supplies the two inputs that are not in the manifest: the source
// a request cites, and hand-written entries to imitate. Both are read from the
// repository, so enrichment sees exactly what a person writing the entry would.
type contextSource struct {
	root    string
	overlay overlayProse
	// maxSourceLines caps a handler excerpt. A handler longer than this is
	// summarized by its head, which is where the interesting part of a Go handler
	// (parse, authorize, dispatch) lives.
	maxSourceLines int
}

type overlayProse struct {
	Routes map[string]struct {
		Description string `json:"description"`
		Details     string `json:"details"`
	} `json:"routes"`
	Labels  map[string]string            `json:"labels"`
	DepDocs map[string]map[string]string `json:"depDocs"`
}

func loadContext(root, overlayPath string) (contextSource, error) {
	ctx := contextSource{root: root, maxSourceLines: 120}
	raw, err := os.ReadFile(filepath.Join(root, overlayPath))
	if err != nil {
		return ctx, err
	}
	// The overlay carries far more than prose; only the prose is read, and unknown
	// fields are ignored rather than rejected so the enricher does not have to
	// track the curated schema.
	if err := json.Unmarshal(raw, &ctx.overlay); err != nil {
		return ctx, fmt.Errorf("overlay %s: %w", overlayPath, err)
	}
	return ctx, nil
}

// source returns the function surrounding a "file:line" citation. The excerpt is
// found by text, not by parsing: this program must not depend on go/packages,
// which is what keeps the enricher runnable in a CI job that never builds the
// service.
func (c contextSource) source(cite string) string {
	file, line, ok := splitCite(cite)
	if !ok {
		return ""
	}
	raw, err := os.ReadFile(filepath.Join(c.root, file))
	if err != nil {
		return ""
	}
	lines := strings.Split(string(raw), "\n")
	if line < 1 || line > len(lines) {
		return ""
	}
	start := line - 1
	for start > 0 && !strings.HasPrefix(lines[start], "func ") {
		start--
	}
	end := start
	for end < len(lines)-1 && end-start < c.maxSourceLines {
		end++
		if lines[end] == "}" {
			break
		}
	}
	return strings.Join(lines[start:end+1], "\n")
}

// examples returns up to two hand-written entries of a kind. They are chosen by
// sorted key rather than by similarity, so the same prompt is built on every run
// and a diff in generated prose means the facts moved.
func (c contextSource) examples(kind string) string {
	var out []string
	switch kind {
	case "route":
		for _, key := range sortedKeys(c.overlay.Routes) {
			e := c.overlay.Routes[key]
			if e.Description == "" || e.Details == "" {
				continue
			}
			out = append(out, mustJSON(map[string]any{"route": key, "description": e.Description, "details": e.Details}))
			if len(out) == 2 {
				break
			}
		}
	case "label":
		for _, key := range sortedKeys(c.overlay.Labels) {
			if c.overlay.Labels[key] == "" {
				continue
			}
			out = append(out, mustJSON(map[string]any{"node": key, "label": c.overlay.Labels[key]}))
			if len(out) == 2 {
				break
			}
		}
	case "node":
		for _, key := range sortedKeys(c.overlay.DepDocs) {
			docs := c.overlay.DepDocs[key]
			complete := true
			for _, field := range prose.DocFields {
				if strings.TrimSpace(docs[field]) == "" {
					complete = false
					break
				}
			}
			if !complete {
				continue
			}
			out = append(out, mustJSON(map[string]any{"node": key, "docs": docs}))
			if len(out) == 2 {
				break
			}
		}
	}
	return strings.Join(out, "\n\n")
}

func splitCite(cite string) (file string, line int, ok bool) {
	idx := strings.LastIndex(cite, ":")
	if idx < 0 {
		return "", 0, false
	}
	n, err := strconv.Atoi(cite[idx+1:])
	if err != nil {
		return "", 0, false
	}
	return cite[:idx], n, true
}

func mustJSON(v any) string {
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(raw)
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
