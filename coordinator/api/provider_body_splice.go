package api

// provider_body_splice.go is the allocation-free fast path behind the
// protocol-0 cache-isolation sizing and sealing (bodyForCacheAttempt and its
// size-only callers) and the legacy vision penalty strip (bodyForProvider).
//
// Those helpers used to decode the whole provider body into
// map[string]json.RawMessage and re-encode it — twice per candidate model per
// request, and again per dispatch attempt — just to add one top-level member
// (or check whether a few exist). For a body the coordinator itself serialized
// (marshalForwardBody: compact, keys sorted, canonical string escaping) the
// re-encode is the identity on every existing member, so the sealed body is
// the input with `"prompt_cache_key":<value>` spliced in at its sorted
// position, and its size is plain arithmetic.
//
// Exactness argument (encoding/json, escapeHTML=false): a RawMessage value is
// re-emitted through compact, which only drops whitespace outside strings;
// object keys are decoded and re-encoded with appendString, then sorted by
// strings.Compare. So the re-encode is byte-identical to a splice iff (1) the
// body carries no insignificant whitespace anywhere, (2) every top-level key
// is escape-free printable ASCII without `"`/`\` (decoded == raw, and
// re-encoding is the identity), and (3) the keys are strictly increasing
// (already sorted, no duplicates to collapse). Anything else — a caller's
// verbatim pretty-printed body, non-ASCII keys, duplicates — takes the
// decode/re-encode path exactly as before. Bodies reaching these helpers have
// already been parsed once by the prelude (or serialized by the coordinator),
// so the scanner validates structure, literals and numbers but not string
// escape sequences.

import (
	"bytes"
	"sort"
)

// topLevelMember locates one member of a JSON object body.
type topLevelMember struct {
	keyStart, keyEnd     int // body[keyStart:keyEnd] is the quoted key, quotes included
	valueStart, valueEnd int // body[valueStart:valueEnd] is the raw value
}

// topLevelIndex describes the top-level members of a JSON object body and the
// properties the fast paths rely on.
type topLevelIndex struct {
	members []topLevelMember
	// compact: no whitespace outside strings anywhere in the body.
	compact bool
	// plainKeys: every top-level key is escape-free printable ASCII without
	// `"` or `\`, so its decoded form is exactly its raw bytes.
	plainKeys bool
	// sorted: the keys are strictly increasing in byte order.
	sorted bool
}

// canonical reports whether re-encoding the body's members is the identity.
func (idx topLevelIndex) canonical() bool {
	return idx.compact && idx.plainKeys && idx.sorted
}

// rawKey returns the unquoted raw key bytes of a member.
func (idx topLevelIndex) rawKey(body []byte, m topLevelMember) []byte {
	return body[m.keyStart+1 : m.keyEnd-1]
}

// find returns the position of the first member whose raw key equals key.
func (idx topLevelIndex) find(body []byte, key string) (int, bool) {
	for i, m := range idx.members {
		if string(idx.rawKey(body, m)) == key {
			return i, true
		}
	}
	return 0, false
}

func isJSONWhitespace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

func isPlainKeyByte(b byte) bool {
	return b >= 0x20 && b < 0x7f && b != '"' && b != '\\'
}

// indexTopLevelObject scans body as a single JSON object. ok=false when body
// is not a structurally valid object (the caller then decodes it for real).
func indexTopLevelObject(body []byte) (topLevelIndex, bool) {
	idx := topLevelIndex{compact: true, plainKeys: true, sorted: true}
	i := 0
	skipSpace := func() {
		for i < len(body) && isJSONWhitespace(body[i]) {
			idx.compact = false
			i++
		}
	}
	skipSpace()
	if i >= len(body) || body[i] != '{' {
		return topLevelIndex{}, false
	}
	i++
	var previousKey []byte
	for {
		skipSpace()
		if i >= len(body) {
			return topLevelIndex{}, false
		}
		if body[i] == '}' {
			if len(idx.members) > 0 && body[i-1] == ',' {
				return topLevelIndex{}, false // trailing comma
			}
			i++
			skipSpace()
			if i != len(body) {
				return topLevelIndex{}, false // trailing content
			}
			return idx, true
		}
		if len(idx.members) > 0 {
			if body[i] != ',' {
				return topLevelIndex{}, false
			}
			i++
			skipSpace()
			if i >= len(body) {
				return topLevelIndex{}, false
			}
		}
		if body[i] != '"' {
			return topLevelIndex{}, false
		}
		var m topLevelMember
		m.keyStart = i
		end, ok := scanJSONString(body, i)
		if !ok {
			return topLevelIndex{}, false
		}
		m.keyEnd = end
		i = end
		key := body[m.keyStart+1 : m.keyEnd-1]
		for _, b := range key {
			if !isPlainKeyByte(b) {
				idx.plainKeys = false
				break
			}
		}
		if previousKey != nil && bytes.Compare(previousKey, key) >= 0 {
			idx.sorted = false
		}
		previousKey = key
		skipSpace()
		if i >= len(body) || body[i] != ':' {
			return topLevelIndex{}, false
		}
		i++
		skipSpace()
		m.valueStart = i
		end, compact, ok := scanJSONValue(body, i)
		if !ok {
			return topLevelIndex{}, false
		}
		if !compact {
			idx.compact = false
		}
		m.valueEnd = end
		i = end
		idx.members = append(idx.members, m)
	}
}

// scanJSONString returns the index just past the closing quote of the string
// starting at body[start] == '"'. Escapes are skipped pairwise (the payload of
// a \uXXXX escape can contain neither `"` nor `\`).
func scanJSONString(body []byte, start int) (int, bool) {
	j := start + 1
	for {
		quote := bytes.IndexByte(body[j:], '"')
		if quote < 0 {
			return 0, false
		}
		escape := bytes.IndexByte(body[j:j+quote], '\\')
		if escape < 0 {
			return j + quote + 1, true
		}
		j += escape + 2
		if j > len(body) {
			return 0, false
		}
	}
}

// scanJSONValue returns the index just past the value starting at body[start]
// and whether it carried no whitespace outside strings.
func scanJSONValue(body []byte, start int) (end int, compact bool, ok bool) {
	if start >= len(body) {
		return 0, false, false
	}
	switch c := body[start]; {
	case c == '"':
		end, ok = scanJSONString(body, start)
		return end, true, ok
	case c == '{' || c == '[':
		return scanJSONContainer(body, start)
	default:
		return scanJSONScalar(body, start)
	}
}

// scanJSONContainer walks a nested object/array with a bracket stack. It
// checks that brackets balance by type and that strings terminate, and
// records whether any whitespace sits outside strings; member structure
// inside is not re-validated (see the file comment).
func scanJSONContainer(body []byte, start int) (end int, compact bool, ok bool) {
	compact = true
	var open []byte
	for i := start; i < len(body); {
		switch b := body[i]; {
		case b == '"':
			next, ok := scanJSONString(body, i)
			if !ok {
				return 0, false, false
			}
			i = next
		case b == '{' || b == '[':
			open = append(open, b)
			i++
		case b == '}' || b == ']':
			want := byte('{')
			if b == ']' {
				want = '['
			}
			if len(open) == 0 || open[len(open)-1] != want {
				return 0, false, false
			}
			open = open[:len(open)-1]
			i++
			if len(open) == 0 {
				return i, compact, true
			}
		case isJSONWhitespace(b):
			compact = false
			i++
		default:
			i++
		}
	}
	return 0, false, false
}

// scanJSONScalar accepts the literals true/false/null and JSON numbers.
func scanJSONScalar(body []byte, start int) (end int, compact bool, ok bool) {
	end = start
	for end < len(body) {
		b := body[end]
		if b == ',' || b == '}' || b == ']' || isJSONWhitespace(b) {
			break
		}
		end++
	}
	literal := body[start:end]
	switch string(literal) {
	case "true", "false", "null":
		return end, true, true
	}
	if jsonNumberLiteralValid(string(literal)) {
		return end, true, true
	}
	return 0, false, false
}

// spliceTopLevelMember returns body with key set to valueJSON — replacing an
// existing member or inserting at the sorted position — when body is
// canonical, so the result is byte-identical to decoding body into
// map[string]json.RawMessage, setting the key, and marshalForwardBody-ing it.
// ok=false means the caller must take that decode path.
func spliceTopLevelMember(body []byte, key string, valueJSON []byte) ([]byte, bool) {
	idx, ok := indexTopLevelObject(body)
	if !ok || !idx.canonical() {
		return nil, false
	}
	if pos, exists := idx.find(body, key); exists {
		m := idx.members[pos]
		out := make([]byte, 0, len(body)-(m.valueEnd-m.valueStart)+len(valueJSON))
		out = append(out, body[:m.valueStart]...)
		out = append(out, valueJSON...)
		out = append(out, body[m.valueEnd:]...)
		return out, true
	}
	at, insertBefore := insertionPoint(body, idx, key)
	out := make([]byte, 0, len(body)+len(key)+3+len(valueJSON)+1)
	out = append(out, body[:at]...)
	if !insertBefore && len(idx.members) > 0 {
		out = append(out, ',')
	}
	out = append(out, '"')
	out = append(out, key...)
	out = append(out, '"', ':')
	out = append(out, valueJSON...)
	if insertBefore {
		out = append(out, ',')
	}
	out = append(out, body[at:]...)
	return out, true
}

// splicedTopLevelMemberSize is the arithmetic twin of spliceTopLevelMember:
// the length the spliced body would have, without building it.
func splicedTopLevelMemberSize(body []byte, key string, valueJSON []byte) (int, bool) {
	idx, ok := indexTopLevelObject(body)
	if !ok || !idx.canonical() {
		return 0, false
	}
	if pos, exists := idx.find(body, key); exists {
		m := idx.members[pos]
		return len(body) - (m.valueEnd - m.valueStart) + len(valueJSON), true
	}
	size := len(body) + len(key) + 3 + len(valueJSON) // "key": + value
	if len(idx.members) > 0 {
		size++ // separating comma
	}
	return size, true
}

// insertionPoint returns where a new member with key belongs in a sorted
// canonical body: before the first member whose key sorts after it
// (insertBefore=true, the new member gets a trailing comma) or, when no such
// member exists, at the closing brace (a leading comma unless the object is
// empty).
func insertionPoint(body []byte, idx topLevelIndex, key string) (at int, insertBefore bool) {
	pos := sort.Search(len(idx.members), func(i int) bool {
		return string(idx.rawKey(body, idx.members[i])) > key
	})
	if pos < len(idx.members) {
		return idx.members[pos].keyStart, true
	}
	return len(body) - 1, false
}

// topLevelObjectHasAnyKey reports whether body carries any of keys as a
// top-level member. ok=false when body is not an indexable object or a key is
// not plain (an escaped spelling could decode to a listed key), in which case
// the caller must decode for real.
func topLevelObjectHasAnyKey(body []byte, keys []string) (has bool, ok bool) {
	idx, ok := indexTopLevelObject(body)
	if !ok || !idx.plainKeys {
		return false, false
	}
	for _, key := range keys {
		if _, exists := idx.find(body, key); exists {
			return true, true
		}
	}
	return false, true
}
