package api

import (
	"encoding/json"
	"math/rand/v2"
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

// TestJSONValueLenMatchesMarshal is the property test: random decoder-shaped
// trees seeded with the special strings must measure exactly like the encoder,
// and the wrapper must agree with marshal-and-measure for everything else.
func TestJSONValueLenMatchesMarshal(t *testing.T) {
	rnd := rand.New(rand.NewPCG(3, 9))
	var gen func(depth int) any
	gen = func(depth int) any {
		switch k := rnd.IntN(8); {
		case k == 0:
			return nil
		case k == 1:
			return rnd.IntN(2) == 0
		case k == 2:
			return json.Number([]string{"0", "-1", "3.25", "1e10", "9007199254740993"}[rnd.IntN(5)])
		case k <= 4 || depth > 3:
			return jsonLenSpecialStrings[rnd.IntN(len(jsonLenSpecialStrings))]
		case k == 5:
			m := make(map[string]any)
			for i := rnd.IntN(4); i > 0; i-- {
				m[jsonLenSpecialStrings[rnd.IntN(len(jsonLenSpecialStrings))]+string(rune('a'+i))] = gen(depth + 1)
			}
			return m
		default:
			arr := make([]any, rnd.IntN(4))
			for i := range arr {
				arr[i] = gen(depth + 1)
			}
			return arr
		}
	}
	for i := 0; i < 2000; i++ {
		v := gen(0)
		want, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		if got := jsonValueLen(v); got != len(want) {
			t.Fatalf("tree %d: len = %d, want %d for %s", i, got, len(want), want)
		}
	}
	// Fallback path: values the counter declines still measure exactly, and an
	// unencodable value reports 0 like the marshal-and-measure path.
	if got := jsonValueLen(map[string]any{"n": 42, "f": 0.5}); got != len(`{"f":0.5,"n":42}`) {
		t.Fatalf("fallback len = %d", got)
	}
	if got := jsonValueLen(map[string]any{"bad": json.Number("nope")}); got != 0 {
		t.Fatalf("unencodable value len = %d, want 0", got)
	}
}

func TestJSONNumberLiteralValid(t *testing.T) {
	valid := []string{"0", "-0", "1", "-12", "1.5", "0.25", "1e5", "1E+5", "2.5e-3", "9007199254740993"}
	invalid := []string{"", "-", "+1", "01", "1.", ".5", "1e", "1e+", "0x10", "nope", "1 ", "--1"}
	for _, s := range valid {
		if !jsonNumberLiteralValid(s) {
			t.Errorf("%q rejected", s)
		}
		if _, err := json.Marshal(json.Number(s)); err != nil {
			t.Errorf("%q: encoder disagrees: %v", s, err)
		}
	}
	for _, s := range invalid {
		if jsonNumberLiteralValid(s) {
			t.Errorf("%q accepted", s)
		}
		if s == "" {
			continue // the encoder substitutes "0" for the zero value
		}
		if _, err := json.Marshal(json.Number(s)); err == nil {
			t.Errorf("%q: encoder disagrees (accepted)", s)
		}
	}
}
