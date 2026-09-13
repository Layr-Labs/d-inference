package api

// provider_body_splice.go is the allocation-free fast path behind the
// protocol-0 cache-isolation sizing and sealing (bodyForCacheAttempt and its
// size-only callers, see provider_body_seal.go) and the legacy vision penalty
// strip (bodyForProvider).
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
// decode/re-encode path exactly as before.
//
// The scanner is a complete structural validator of the JSON grammar
// encoding/json's scanner accepts (object/array structure, string escapes and
// control bytes, number and literal syntax, nesting bounded well below the
// decoder's limit), so a body it indexes is one the decode path would have
// accepted; it does not check UTF-8 validity, which the decoder does not
// reject either (RawMessage values are copied verbatim).

import (
	"bytes"
	"encoding/binary"
	"sort"
)

// maxSpliceNestingDepth bounds the recursive scan. It sits well under
// encoding/json's own limit (10000), so a body nested deeper is simply handed
// to the decode path, which stays the authority on whether it is accepted.
const maxSpliceNestingDepth = 8192

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

// noteMember records a top-level member and folds its key into the
// plainKeys / sorted verdicts.
func (idx *topLevelIndex) noteMember(body []byte, m topLevelMember) {
	key := body[m.keyStart+1 : m.keyEnd-1]
	for _, b := range key {
		if !isPlainKeyByte(b) {
			idx.plainKeys = false
			break
		}
	}
	if n := len(idx.members); n > 0 {
		previous := idx.rawKey(body, idx.members[n-1])
		if bytes.Compare(previous, key) >= 0 {
			idx.sorted = false
		}
	}
	idx.members = append(idx.members, m)
}

func isJSONWhitespace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

func isPlainKeyByte(b byte) bool {
	return b >= 0x20 && b < 0x7f && b != '"' && b != '\\'
}

func isHexDigit(b byte) bool {
	return ('0' <= b && b <= '9') || ('a' <= b && b <= 'f') || ('A' <= b && b <= 'F')
}

// skipJSONSpace advances past insignificant whitespace and reports whether
// any was present.
func skipJSONSpace(body []byte, i int) (int, bool) {
	start := i
	for i < len(body) && isJSONWhitespace(body[i]) {
		i++
	}
	return i, i != start
}

// indexTopLevelObject scans body as a single JSON object, validating the full
// grammar on the way. ok=false when body is not a valid object (the caller
// then decodes it for real, which reports the same verdict).
func indexTopLevelObject(body []byte) (topLevelIndex, bool) {
	idx := topLevelIndex{compact: true, plainKeys: true, sorted: true}
	i, ws := skipJSONSpace(body, 0)
	if ws {
		idx.compact = false
	}
	if i >= len(body) || body[i] != '{' {
		return topLevelIndex{}, false
	}
	end, compact, ok := scanJSONObject(body, i, 1, &idx)
	if !ok {
		return topLevelIndex{}, false
	}
	if !compact {
		idx.compact = false
	}
	i, ws = skipJSONSpace(body, end)
	if ws {
		idx.compact = false
	}
	if i != len(body) {
		return topLevelIndex{}, false // trailing content
	}
	return idx, true
}

// scanJSONValue validates the value starting at body[i] and returns the index
// just past it, plus whether it carried no whitespace outside strings.
func scanJSONValue(body []byte, i, depth int) (end int, compact bool, ok bool) {
	if i >= len(body) {
		return 0, false, false
	}
	switch body[i] {
	case '"':
		end, ok = scanJSONString(body, i)
		return end, true, ok
	case '{':
		return scanJSONObject(body, i, depth+1, nil)
	case '[':
		return scanJSONArray(body, i, depth+1)
	default:
		return scanJSONScalar(body, i)
	}
}

// scanJSONObject validates an object starting at body[i] == '{'. idx, when
// non-nil, receives the object's members (only the top level asks).
func scanJSONObject(body []byte, i, depth int, idx *topLevelIndex) (end int, compact bool, ok bool) {
	if depth > maxSpliceNestingDepth {
		return 0, false, false
	}
	compact = true
	i++ // '{'
	var ws bool
	if i, ws = skipJSONSpace(body, i); ws {
		compact = false
	}
	if i < len(body) && body[i] == '}' {
		return i + 1, compact, true
	}
	for {
		if i >= len(body) || body[i] != '"' {
			return 0, false, false
		}
		var m topLevelMember
		m.keyStart = i
		if i, ok = scanJSONString(body, i); !ok {
			return 0, false, false
		}
		m.keyEnd = i
		if i, ws = skipJSONSpace(body, i); ws {
			compact = false
		}
		if i >= len(body) || body[i] != ':' {
			return 0, false, false
		}
		i++
		if i, ws = skipJSONSpace(body, i); ws {
			compact = false
		}
		m.valueStart = i
		var valueCompact bool
		if i, valueCompact, ok = scanJSONValue(body, i, depth); !ok {
			return 0, false, false
		}
		if !valueCompact {
			compact = false
		}
		m.valueEnd = i
		if idx != nil {
			idx.noteMember(body, m)
		}
		if i, ws = skipJSONSpace(body, i); ws {
			compact = false
		}
		if i >= len(body) {
			return 0, false, false
		}
		switch body[i] {
		case ',':
			i++
			if i, ws = skipJSONSpace(body, i); ws {
				compact = false
			}
		case '}':
			return i + 1, compact, true
		default:
			return 0, false, false
		}
	}
}

// scanJSONArray validates an array starting at body[i] == '['.
func scanJSONArray(body []byte, i, depth int) (end int, compact bool, ok bool) {
	if depth > maxSpliceNestingDepth {
		return 0, false, false
	}
	compact = true
	i++ // '['
	var ws bool
	if i, ws = skipJSONSpace(body, i); ws {
		compact = false
	}
	if i < len(body) && body[i] == ']' {
		return i + 1, compact, true
	}
	for {
		var valueCompact bool
		if i, valueCompact, ok = scanJSONValue(body, i, depth); !ok {
			return 0, false, false
		}
		if !valueCompact {
			compact = false
		}
		if i, ws = skipJSONSpace(body, i); ws {
			compact = false
		}
		if i >= len(body) {
			return 0, false, false
		}
		switch body[i] {
		case ',':
			i++
			if i, ws = skipJSONSpace(body, i); ws {
				compact = false
			}
		case ']':
			return i + 1, compact, true
		default:
			return 0, false, false
		}
	}
}

// scanJSONString validates the string starting at body[start] == '"' and
// returns the index just past its closing quote: no raw control bytes, only
// the escapes the grammar allows (\" \\ \/ \b \f \n \r \t \uXXXX). The
// closing-quote search is SIMD-assisted and every byte is examined once, so
// a long string with many escapes stays linear.
func scanJSONString(body []byte, start int) (int, bool) {
	j := start + 1
	quotePos := -1
	for {
		if quotePos < j {
			q := bytes.IndexByte(body[j:], '"')
			if q < 0 {
				return 0, false
			}
			quotePos = j + q
		}
		escape := bytes.IndexByte(body[j:quotePos], '\\')
		if escape < 0 {
			if hasControlByte(body[j:quotePos]) {
				return 0, false
			}
			return quotePos + 1, true
		}
		e := j + escape
		if hasControlByte(body[j:e]) || e+1 >= len(body) {
			return 0, false
		}
		switch body[e+1] {
		case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
			j = e + 2
		case 'u':
			if e+6 > len(body) {
				return 0, false
			}
			for _, h := range body[e+2 : e+6] {
				if !isHexDigit(h) {
					return 0, false
				}
			}
			j = e + 6
		default:
			return 0, false
		}
	}
}

// hasControlByte reports whether b contains any byte below 0x20, eight bytes
// at a time.
func hasControlByte(b []byte) bool {
	const (
		ones = 0x0101010101010101
		high = 0x8080808080808080
	)
	for len(b) >= 8 {
		v := binary.LittleEndian.Uint64(b)
		if (v-ones*0x20)&^v&high != 0 {
			return true
		}
		b = b[8:]
	}
	for _, c := range b {
		if c < 0x20 {
			return true
		}
	}
	return false
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
// top-level member. ok=false when body is not a valid object or a key is
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
