package protocol

import "strings"

// Lightweight top-level key scanner used by ProviderMessage.UnmarshalJSON so
// the message "type" can be read without a full envelope json.Unmarshal pass.
// Every provider frame — including one per streamed token — used to be parsed
// twice (envelope + concrete struct); the scanner makes the type lookup a
// short byte walk so the full parse happens exactly once.
//
// The scanner is deliberately conservative: whenever it meets anything it is
// not 100% sure about (escape sequences, non-string type values, malformed
// input) it reports failure and the caller falls back to the full envelope
// decode. It never needs to be *complete*, only never-wrong.

// scanTopLevelString returns the raw string value of a top-level object key.
// ok is false when the key is absent, appears more than once (including
// case-insensitive variants — encoding/json matches keys case-insensitively
// and last-match-wins), its value is not a plain (escape-free) string, or the
// input isn't a well-formed-enough object — callers must fall back to
// encoding/json. Bailing on duplicates keeps the fast path behaviorally
// identical to a full decode: picking either occurrence here could disagree
// with the concrete-struct unmarshal that follows.
func scanTopLevelString(data []byte, key string) (value string, ok bool) {
	i := skipJSONWhitespace(data, 0)
	if i >= len(data) || data[i] != '{' {
		return "", false
	}
	i = skipJSONWhitespace(data, i+1)
	if i < len(data) && data[i] == '}' {
		return "", false
	}
	found := false
	for {
		k, next, kOK := scanSimpleJSONString(data, i)
		if !kOK {
			return "", false
		}
		i = skipJSONWhitespace(data, next)
		if i >= len(data) || data[i] != ':' {
			return "", false
		}
		i = skipJSONWhitespace(data, i+1)
		if strings.EqualFold(string(k), key) {
			// A repeated key, or a case-variant ("Type") that encoding/json
			// would also match: defer to the full decode. Real provider
			// frames never emit duplicates; correctness beats speed here.
			if found || string(k) != key {
				return "", false
			}
			v, vNext, vOK := scanSimpleJSONString(data, i)
			if !vOK {
				return "", false
			}
			value, found = string(v), true
			i = vNext
		} else {
			vNext, vOK := skipJSONValue(data, i)
			if !vOK {
				return "", false
			}
			i = vNext
		}
		i = skipJSONWhitespace(data, i)
		if i >= len(data) {
			return "", false
		}
		switch data[i] {
		case ',':
			i = skipJSONWhitespace(data, i+1)
		case '}':
			if found {
				return value, true
			}
			return "", false // key not present
		default:
			return "", false
		}
	}
}

func skipJSONWhitespace(data []byte, i int) int {
	for i < len(data) {
		switch data[i] {
		case ' ', '\t', '\n', '\r':
			i++
		default:
			return i
		}
	}
	return i
}

// scanSimpleJSONString scans a JSON string starting at data[i] and returns its
// raw bytes and the index after the closing quote. It bails on any escape
// sequence so it never has to implement unescaping.
func scanSimpleJSONString(data []byte, i int) (s []byte, next int, ok bool) {
	if i >= len(data) || data[i] != '"' {
		return nil, 0, false
	}
	i++
	start := i
	for i < len(data) {
		switch data[i] {
		case '\\':
			return nil, 0, false
		case '"':
			return data[start:i], i + 1, true
		}
		i++
	}
	return nil, 0, false
}

// skipJSONValue advances past one JSON value (string, object, array, number,
// bool, or null) starting at data[i], returning the index just after it.
func skipJSONValue(data []byte, i int) (next int, ok bool) {
	if i >= len(data) {
		return 0, false
	}
	switch data[i] {
	case '"':
		return skipJSONString(data, i)
	case '{', '[':
		depth := 0
		for i < len(data) {
			switch data[i] {
			case '"':
				n, ok := skipJSONString(data, i)
				if !ok {
					return 0, false
				}
				i = n
				continue
			case '{', '[':
				depth++
			case '}', ']':
				depth--
				if depth == 0 {
					return i + 1, true
				}
			}
			i++
		}
		return 0, false
	default:
		// Number, true, false, or null: scan to the next structural byte.
		for i < len(data) {
			switch data[i] {
			case ',', '}', ']', ' ', '\t', '\n', '\r':
				return i, true
			}
			i++
		}
		return 0, false
	}
}

// skipJSONString advances past the JSON string starting at data[i] (which must
// be '"'), handling escape sequences.
func skipJSONString(data []byte, i int) (next int, ok bool) {
	i++
	for i < len(data) {
		switch data[i] {
		case '\\':
			i += 2
		case '"':
			return i + 1, true
		default:
			i++
		}
	}
	return 0, false
}
