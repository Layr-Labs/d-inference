package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// legacySealCacheBust is the pre-fast-path implementation of the protocol-0
// cache-bust seal: decode into RawMessages, set the key, re-encode.
func legacySealCacheBust(t *testing.T, body []byte, key string) []byte {
	t.Helper()
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("legacy seal decode: %v", err)
	}
	keyJSON, _ := json.Marshal(key)
	parsed["prompt_cache_key"] = keyJSON
	sealed, err := marshalForwardBody(parsed)
	if err != nil {
		t.Fatal(err)
	}
	return sealed
}

// legacyStripPenalties is the pre-fast-path vision penalty strip.
func legacyStripPenalties(t *testing.T, body []byte) []byte {
	t.Helper()
	parsed, err := decodeInferenceJSONObject(body)
	if err != nil {
		return body
	}
	changed := false
	for _, key := range visionPenaltyFields {
		if _, ok := parsed[key]; ok {
			delete(parsed, key)
			changed = true
		}
	}
	if !changed {
		return body
	}
	out, err := marshalForwardBody(parsed)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func forwardBytes(t *testing.T, v any) []byte {
	t.Helper()
	b, err := marshalForwardBody(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type spliceCase struct {
	body []byte
	// fast reports whether the splice fast path must fire (canonical body).
	fast bool
}

func spliceCases(t *testing.T) map[string]spliceCase {
	t.Helper()
	nested := map[string]any{
		"messages": []any{map[string]any{"role": "user", "content": "a <b> & \"c\"\n\t\\   end"}},
		"model":    "m",
		"tools": []any{map[string]any{"type": "function", "function": map[string]any{
			"name": "f", "parameters": map[string]any{"type": "object", "properties": map[string]any{}, "required": []any{}},
		}}},
		"temperature": json.Number("0.5"),
		"stream":      true,
		"stop":        nil,
		"metadata":    map[string]any{"exact": json.Number("9007199254740993"), "arr": []any{json.Number("1"), false, nil, "x"}},
	}
	return map[string]spliceCase{
		"canonical nested":            {forwardBytes(t, nested), true},
		"canonical empty object":      {[]byte(`{}`), true},
		"canonical single member":     {[]byte(`{"model":"m"}`), true},
		"canonical key sorts first":   {[]byte(`{"a":1,"b":[1,2,{"c":"d"}]}`), true},
		"canonical key sorts last":    {[]byte(`{"prompt":"x","z":"y"}`), true},
		"canonical key sorts between": {[]byte(`{"messages":[],"prompt":"x","temperature":1}`), true},
		"canonical existing key":      {forwardBytes(t, map[string]any{"model": "m", "prompt_cache_key": "old-key", "z": json.Number("1")}), true},
		"canonical existing key last": {[]byte(`{"model":"m","prompt_cache_key":"old"}`), true},
		"canonical invalid utf8":      {forwardBytes(t, map[string]any{"model": "m", "text": "bad \xff\xfe bytes"}), true},
		"canonical escapes in values": {[]byte(`{"a":"quote \" backslash \\ A \\\"","b":"{not an object}","c":"[nor array],"}`), true},
		// Raw (not coordinator-serialized) canonical bodies: values are copied
		// verbatim by both paths, whatever they contain.
		"canonical raw line separators": {[]byte("{\"a\":\"x\u2028y\u2029z\",\"b\":\"\\u2028 escaped\"}"), true},
		"canonical raw invalid utf8":    {[]byte("{\"a\":\"bad \xff\xfe\xc0 bytes\",\"b\":1}"), true},
		"canonical number forms":        {[]byte(`{"a":1e5,"b":-0,"c":1.0,"d":1E+5,"e":` + strings.Repeat("9", 300) + `,"f":[0.5e-7,-12.25E3,0]}`), true},
		"canonical html and slashes":    {[]byte(`{"a":"<b>&amp;</b> http:\/\/x <"}`), true},
		"canonical del in key":          {[]byte("{\"k\x7f\":1}"), false},
		"pretty printed":                {[]byte("{\n  \"model\": \"m\",\n  \"messages\": []\n}"), false},
		"whitespace inside nested":      {[]byte(`{"a":[1, 2],"b":"x"}`), false},
		"unsorted keys":                 {[]byte(`{"z":1,"a":2}`), false},
		"duplicate keys":                {[]byte(`{"a":1,"a":2}`), false},
		"escaped key":                   {[]byte(`{"pro\u006dpt":"x"}`), false},
		"non-ascii key":                 {[]byte(`{"ключ":"x"}`), false},
		"key with quote escape":         {[]byte(`{"a\"b":"x"}`), false},
		"leading whitespace":            {[]byte(` {"a":1}`), false},
		"trailing newline":              {[]byte("{\"a\":1}\n"), false},
	}
}

// Every case must seal to exactly what the decode/re-encode path produced,
// and the arithmetic size must equal the sealed length — whether or not the
// fast path fired, and the fast path must fire exactly for canonical bodies.
func TestCacheBustSpliceMatchesReencode(t *testing.T) {
	const key = "darkbloom-uncached-0123456789abcdefghijkl"
	keyJSON, _ := json.Marshal(key)
	for name, tc := range spliceCases(t) {
		t.Run(name, func(t *testing.T) {
			want := legacySealCacheBust(t, tc.body, key)
			got, err := bodyForCacheAttempt(tc.body, false, nil, &registry.PendingRequest{LegacyCacheBustKey: key})
			if err != nil {
				t.Fatalf("bodyForCacheAttempt: %v", err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("sealed body diverged:\n got %s\nwant %s", got, want)
			}
			size, err := cacheAttemptSealedSize(tc.body, key)
			if err != nil || size != len(want) {
				t.Fatalf("sealed size = %d (%v), want %d", size, err, len(want))
			}
			if _, fast := spliceTopLevelMember(tc.body, legacyCacheBustField, keyJSON); fast != tc.fast {
				t.Fatalf("fast path fired = %v, want %v", fast, tc.fast)
			}
			if _, fast := splicedTopLevelMemberSize(tc.body, legacyCacheBustField, keyJSON); fast != tc.fast {
				t.Fatalf("size fast path fired = %v, want %v", fast, tc.fast)
			}
			// A second seal of the sealed body (the key already present) also matches.
			resealed, err := bodyForCacheAttempt(want, false, nil, &registry.PendingRequest{LegacyCacheBustKey: "second-key"})
			if err != nil {
				t.Fatal(err)
			}
			if wantResealed := legacySealCacheBust(t, want, "second-key"); !bytes.Equal(resealed, wantResealed) {
				t.Fatalf("resealed body diverged:\n got %s\nwant %s", resealed, wantResealed)
			}
		})
	}
}

// TestCacheBustSplicePropertyMatchesReencode is the property test: random
// decoder-shaped objects serialized by marshalForwardBody (canonical unless a
// key is not plain ASCII) and their json.Indent perturbations (never
// canonical, except the empty object) must seal and size exactly like the
// decode/re-encode reference, and the fast path must fire exactly when the
// body is canonical.
func TestCacheBustSplicePropertyMatchesReencode(t *testing.T) {
	rnd := rand.New(rand.NewPCG(5, 8))
	keys := []string{"a", "model", "messages", "prompt_cache_key", "zeta", "x<y>", "k\"q", "ключ", "tab\there", "prompt_cache_key2", "", "Z"}
	values := []string{"", "plain", "quote\" backslash\\", "\n\t\b", "<html>&", "line\u2028sep", "bad\xffutf8", "emoji 🎉", "}{][,:"}
	var gen func(depth int) any
	gen = func(depth int) any {
		switch k := rnd.IntN(8); {
		case k == 0:
			return nil
		case k == 1:
			return rnd.IntN(2) == 0
		case k == 2:
			return json.Number([]string{"0", "-0", "1.0", "1e5", "1E+5", "-12.25E3", strings.Repeat("7", 40)}[rnd.IntN(7)])
		case k <= 4 || depth > 3:
			return values[rnd.IntN(len(values))]
		case k == 5:
			m := make(map[string]any)
			for i := rnd.IntN(4); i > 0; i-- {
				m[keys[rnd.IntN(len(keys))]] = gen(depth + 1)
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
	check := func(i int, body []byte, key string, expectFast bool) {
		t.Helper()
		want := legacySealCacheBust(t, body, key)
		got, err := bodyForCacheAttempt(body, false, nil, &registry.PendingRequest{LegacyCacheBustKey: key})
		if err != nil {
			t.Fatalf("tree %d: seal: %v", i, err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("tree %d: sealed body diverged:\n body %s\n got %s\nwant %s", i, body, got, want)
		}
		if size, err := cacheAttemptSealedSize(body, key); err != nil || size != len(want) {
			t.Fatalf("tree %d: size = %d (%v), want %d", i, size, err, len(want))
		}
		keyJSON, _ := json.Marshal(key)
		if _, fast := spliceTopLevelMember(body, legacyCacheBustField, keyJSON); fast != expectFast {
			t.Fatalf("tree %d: fast path fired = %v, want %v for %s", i, fast, expectFast, body)
		}
	}
	for i := 0; i < 500; i++ {
		obj := make(map[string]any)
		for n := rnd.IntN(7); n > 0; n-- {
			obj[keys[rnd.IntN(len(keys))]] = gen(0)
		}
		plain := true
		for k := range obj {
			for _, b := range []byte(k) {
				if !isPlainKeyByte(b) {
					plain = false
				}
			}
		}
		key := fmt.Sprintf("darkbloom-uncached-%03d", i)
		canonical := forwardBytes(t, obj)
		check(i, canonical, key, plain)
		var indented bytes.Buffer
		if err := json.Indent(&indented, canonical, "", "  "); err != nil {
			t.Fatal(err)
		}
		// Indentation adds whitespace outside strings unless the object is empty.
		check(i, indented.Bytes(), key, plain && len(obj) == 0)
	}
}

// The size-only verdict must match the byte-building verdict at the cap.
func TestCacheAttemptSizeErrorMatchesSeal(t *testing.T) {
	key := strings.Repeat("x", registry.LegacyCacheBustKeyLength)
	sealedOverhead := len(`,"prompt_cache_key":""`) + len(key)
	for _, delta := range []int{-1, 0, 1} {
		fill := maxInferenceBodyBytes - sealedOverhead - len(`{"payload":""}`) + delta
		body := []byte(`{"payload":"` + strings.Repeat("x", fill) + `"}`)
		_, sealErr := bodyForCacheAttempt(body, false, nil, &registry.PendingRequest{LegacyCacheBustKey: key})
		size, sizeErr := cacheAttemptSizeError(body, key)
		if (sealErr == nil) != (sizeErr == nil) {
			t.Fatalf("delta %d: seal err %v, size err %v", delta, sealErr, sizeErr)
		}
		if sealErr != nil && size != oversizedProviderBodyBytes(sealErr) {
			t.Fatalf("delta %d: size %d, seal reported %d", delta, size, oversizedProviderBodyBytes(sealErr))
		}
		if sealErr == nil && size != 0 {
			t.Fatalf("delta %d: fitting body reported size %d", delta, size)
		}
	}
	if _, err := cacheAttemptSizeError([]byte(`not json`), key); err == nil {
		t.Fatal("unsealable body reported no error")
	}
}

func TestBodyForProviderPenaltyFastPath(t *testing.T) {
	legacy := &registry.Provider{Version: "0.6.6"}
	cases := map[string][]byte{
		"no penalties canonical":  forwardBytes(t, map[string]any{"model": "m", "messages": []any{}, "temperature": json.Number("1")}),
		"no penalties pretty":     []byte("{\n \"model\": \"m\"\n}"),
		"presence penalty":        forwardBytes(t, map[string]any{"model": "m", "presence_penalty": json.Number("0.5")}),
		"all penalties unsorted":  []byte(`{"repetition_penalty":1.1,"model":"m","frequency_penalty":0,"presence_penalty":0}`),
		"escaped penalty key":     []byte(`{"model":"m","presence\u005fpenalty":0.5}`),
		"penalty nested only":     []byte(`{"model":"m","x":{"presence_penalty":1}}`),
		"not an object":           []byte(`[1,2]`),
		"invalid json":            []byte(`{"model":`),
		"duplicate penalty":       []byte(`{"presence_penalty":1,"presence_penalty":2,"model":"m"}`),
		"penalty value has quote": []byte(`{"model":"m","presence_penalty":"a\"b"}`),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			want := legacyStripPenalties(t, body)
			got := bodyForProvider(body, true, legacy)
			if !bytes.Equal(got, want) {
				t.Fatalf("legacy provider body diverged:\n got %s\nwant %s", got, want)
			}
			if bytes.Equal(want, body) && len(body) > 0 && &got[0] != &body[0] {
				t.Fatal("unchanged body was copied")
			}
			// Fixed providers and text requests never strip.
			if out := bodyForProvider(body, true, &registry.Provider{Version: penaltySafeProviderVersion}); !bytes.Equal(out, body) {
				t.Fatal("fixed provider body changed")
			}
			if out := bodyForProvider(body, false, legacy); !bytes.Equal(out, body) {
				t.Fatal("text request body changed")
			}
		})
	}
}

func TestIndexTopLevelObjectRejectsMalformedBodies(t *testing.T) {
	for _, body := range []string{
		``, `[1,2]`, `{"a":1`, `{"a" 1}`, `{"a":1}x`, `{"a":tru}`, `{"a":01}`, `{"a":1,}`,
		`{,"a":1}`, `{"a":"unterminated}`, `{"a":[1,2}`, `{"a":{"b":1]}`, `{a:1}`, `{"a":1 "b":2}`,
		`{"a":1}}`, `{"a":"x\"}`,
		// Nested grammar: the scanner must reject what encoding/json rejects, or
		// the splice would succeed where the decode path errors.
		`{"a":[1,,2]}`, `{"a":[1,]}`, `{"a":{"b":}}`, `{"a":{"b":1,}}`, `{"a":[1 2]}`, `{"a":{"b" 1}}`,
		`{"a":[tru]}`, `{"a":{1:2}}`, `{"a":[01]}`, `{"a":[1.]}`, `{"a":[.5]}`, `{"a":[-]}`, `{"a":[1e]}`,
		`{"a":"\x"}`, `{"a":"\u12G4"}`, `{"a":"\u123"}`, "{\"a\":\"tab\there\"}", "{\"a\":[\"nl\nhere\"]}",
		`{"a":["unterminated]}`, `{"a":{"b":"c"}`, `{"a":[[1]}`, `{"a":{"b":[1}}`, `{"a":[]]}`,
	} {
		if _, ok := indexTopLevelObject([]byte(body)); ok {
			t.Errorf("accepted malformed body %q", body)
		}
		if err := json.Unmarshal([]byte(body), new(map[string]json.RawMessage)); err == nil {
			t.Errorf("fixture %q is valid JSON; the scanner would be right to accept it", body)
		}
	}
	idx, ok := indexTopLevelObject([]byte(`{"b":{"x":[1,{"y":"}"}]},"a":"\"","c":null}`))
	if !ok || len(idx.members) != 3 || idx.sorted || !idx.compact || !idx.plainKeys {
		t.Fatalf("index = %+v ok=%v", idx, ok)
	}
}

// Nesting deeper than the scanner's bound is handed to the decode path (which
// stays the authority), never accepted by the fast path.
func TestIndexTopLevelObjectBoundsNesting(t *testing.T) {
	deep := []byte(`{"a":` + strings.Repeat("[", maxSpliceNestingDepth+8) + strings.Repeat("]", maxSpliceNestingDepth+8) + `}`)
	if _, ok := indexTopLevelObject(deep); ok {
		t.Fatal("scanner accepted nesting beyond its bound")
	}
	shallow := []byte(`{"a":` + strings.Repeat("[", 64) + strings.Repeat("]", 64) + `}`)
	if idx, ok := indexTopLevelObject(shallow); !ok || !idx.canonical() {
		t.Fatalf("scanner rejected shallow nesting: ok=%v idx=%+v", ok, idx)
	}
	// Valid escapes, literals and number forms nested anywhere are accepted.
	valid := []byte(`{"a":["\"\\\/\b\f\n\r\té",true,false,null,0,-0,1.5,1e5,1E+5,2.5e-3,{"b":[[]],"c":{}}]}`)
	if idx, ok := indexTopLevelObject(valid); !ok || !idx.canonical() {
		t.Fatalf("scanner rejected valid nested body: ok=%v idx=%+v", ok, idx)
	}
}
