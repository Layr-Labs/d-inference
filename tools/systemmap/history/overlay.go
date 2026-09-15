package history

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Retarget rewrites the overlay so it describes a snapshot's package layout
// instead of today's.
//
// Every package-qualified string in the overlay carries the prefix — the route
// table's package, the traverse and inherit lists, the SQL driver's package, and
// the keys of `deps.fields`, which are what map a struct field to a node
// ("coordinator/api:Server.adminKey"). At a commit where those packages sat under
// `internal/`, none of those keys match, and the extractor reports every field it
// reaches as state no node explains. That is not the overlay being wrong about
// the past; it is the overlay being written in one of two vocabularies. So the
// prefix is translated and the same curated facts apply.
//
// The rewrite is a substring replacement over every string and every map key,
// rather than a list of the fields that are package-qualified. A missed field
// would silently lose a mapping table, and the failure mode of being too eager is
// a rewritten sentence of prose, which changes nothing the graph draws. Prose is
// also why `from` must be specific enough to be unambiguous: "coordinator/" is,
// "coordinator" alone would not be.
//
// What the rewrite cannot do is invent a node for state that only ever existed in
// the past. A snapshot from the vllm era reaches fields whose nodes were deleted
// from the overlay when the subsystem was; those stay unmapped, and the snapshot
// reports them, because inventing a node would be describing a system that never
// ran.
func Retarget(raw []byte, from, to string) ([]byte, error) {
	if from == "" {
		return nil, fmt.Errorf("retarget: empty prefix to replace")
	}
	if from == to {
		return raw, nil
	}
	var tree any
	if err := json.Unmarshal(raw, &tree); err != nil {
		return nil, fmt.Errorf("retarget: %w", err)
	}
	// The overlay is decoded with DisallowUnknownFields, so the rewritten copy must
	// stay the same shape: only strings and keys change, never the structure.
	rewritten := rewrite(tree, from, to)
	out, err := json.Marshal(rewritten)
	if err != nil {
		return nil, fmt.Errorf("retarget: %w", err)
	}
	return out, nil
}

func rewrite(v any, from, to string) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, val := range t {
			out[strings.ReplaceAll(k, from, to)] = rewrite(val, from, to)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, val := range t {
			out[i] = rewrite(val, from, to)
		}
		return out
	case string:
		return strings.ReplaceAll(t, from, to)
	default:
		return v
	}
}
