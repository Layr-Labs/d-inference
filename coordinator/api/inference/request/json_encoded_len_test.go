package request

import (
	"encoding/json"
	"strings"
	"testing"
)

// jsonLenSpecialStrings are the string shapes whose encoded length differs
// from their byte length: every short escape, every other control byte, the
// HTML-significant bytes, DEL (safe), invalid UTF-8 (per-byte �),
// U+2028/U+2029 (escaped unconditionally), a genuine U+FFFD (kept raw), and
// multi-byte runes.
var jsonLenSpecialStrings = []string{
	"",
	"plain ascii",
	"quote\" backslash\\ ",
	"\b\f\n\r\t",
	"\x00\x01\x1f",
	"<tag> & amp",
	"\x7f del is safe",
	"bad utf8 \xff\xfe end",
	"truncated rune \xe2\x82",
	"line\u2028sep\u2029par",
	"replacement \uFFFD kept",
	"émoji 🎉 日本語",
	strings.Repeat("a\"b<c>&\n", 50),
}

func TestJSONStringEncodedLenMatchesEncoder(t *testing.T) {
	for _, s := range jsonLenSpecialStrings {
		want, err := json.Marshal(s)
		if err != nil {
			t.Fatal(err)
		}
		if got := jsonStringEncodedLen(s, true); got != len(want) {
			t.Errorf("escapeHTML=true %q: len = %d, want %d (%s)", s, got, len(want), want)
		}
		var buf strings.Builder
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(s); err != nil {
			t.Fatal(err)
		}
		if got, wantLen := jsonStringEncodedLen(s, false), buf.Len()-1; got != wantLen {
			t.Errorf("escapeHTML=false %q: len = %d, want %d", s, got, wantLen)
		}
	}
}

func TestJSONEncodedLenLeafCases(t *testing.T) {
	cases := map[string]any{
		"nil":            nil,
		"true":           true,
		"false":          false,
		"number":         json.Number("12.5e-3"),
		"negative":       json.Number("-0"),
		"empty number":   json.Number(""), // encodes as 0
		"nil map":        map[string]any(nil),
		"empty map":      map[string]any{},
		"nil slice":      []any(nil),
		"empty slice":    []any{},
		"nested":         map[string]any{"a": []any{nil, true, json.Number("1"), "x"}, "b<": map[string]any{}},
		"special key":    map[string]any{"k\"\n<": json.Number("1")},
		"special values": map[string]any{"s": strings.Join(jsonLenSpecialStrings, "|")},
	}
	for name, v := range cases {
		want, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		got, ok := jsonEncodedLen(v)
		if !ok || got != len(want) {
			t.Errorf("%s: (%d, %v), want (%d, true) for %s", name, got, ok, len(want), want)
		}
	}
	// Outside the decoder-shaped universe the counter must decline so the
	// caller falls back to the real encoder.
	for name, v := range map[string]any{
		"int":            7,
		"float":          1.5,
		"[]string":       []string{"a"},
		"nested int":     map[string]any{"n": 1},
		"invalid number": json.Number("0x10"),
		"leading plus":   json.Number("+1"),
	} {
		if n, ok := jsonEncodedLen(v); ok {
			t.Errorf("%s: counter accepted unmodeled value (%d)", name, n)
		}
	}
}
