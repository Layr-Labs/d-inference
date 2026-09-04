package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// chunkFrameCorpus is the golden corpus for the chunk-frame fast path: real
// wire shapes (Swift provider, Go encoder), the edge shapes encoding/json
// tolerates that the scanner deliberately hands back to it, and malformed
// input. fast pins which shapes the scanner is expected to decode itself; a
// shape the scanner does not take must still decode identically through the
// generic path, and a shape it takes must equal encoding/json's result.
var chunkFrameCorpus = []struct {
	name  string
	frame string
	fast  bool
}{
	// --- production shapes: fast path ---
	{
		name:  "swift sorted keys",
		frame: swiftShapedChunkFrame("0f3a9c1e-6b7d-4a2e-9c5f-1d2e3f4a5b6c", "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A="),
		fast:  true,
	},
	{
		name:  "go struct key order",
		frame: `{"type":"inference_response_chunk","request_id":"req-1","encrypted_data":{"ephemeral_public_key":"a+b/c=","ciphertext":"d+e/f=="}}`,
		fast:  true,
	},
	{
		name:  "whitespace between tokens",
		frame: " \n{ \"request_id\" : \"req-1\" ,\n\t\"encrypted_data\" : { \"ciphertext\" : \"Zm9v\" , \"ephemeral_public_key\" : \"YmFy\" } ,\r\n\"type\" : \"inference_response_chunk\" }\n",
		fast:  true,
	},
	{name: "plaintext data without escapes", frame: `{"type":"inference_response_chunk","request_id":"req-1","data":"data: [DONE]"}`, fast: true},
	{name: "encrypted_data null", frame: `{"type":"inference_response_chunk","request_id":"req-1","encrypted_data":null}`, fast: true},
	{name: "encrypted_data empty object", frame: `{"type":"inference_response_chunk","request_id":"req-1","encrypted_data":{}}`, fast: true},
	{name: "type only", frame: `{"type":"inference_response_chunk"}`, fast: true},
	{name: "empty strings", frame: `{"type":"inference_response_chunk","request_id":"","data":"","encrypted_data":{"ephemeral_public_key":"","ciphertext":""}}`, fast: true},
	{name: "printable ascii edge bytes", frame: `{"type":"inference_response_chunk","request_id":" !#$%&'()*+,-./:;<=>?@[]^_` + "`" + `{|}~"}`, fast: true},

	// --- shapes encoding/json accepts that the scanner defers: fallback ---
	{name: "data with escapes", frame: `{"type":"inference_response_chunk","request_id":"req-1","data":"data: {\"id\":\"x\"}\n\n"}`, fast: false},
	{name: "unicode request_id raw utf8", frame: `{"type":"inference_response_chunk","request_id":"réq-ü-☃"}`, fast: false},
	{name: "unicode escape in request_id", frame: `{"type":"inference_response_chunk","request_id":"r\u00e9q"}`, fast: false},
	{name: "escaped slash", frame: `{"type":"inference_response_chunk","request_id":"a\/b"}`, fast: false},
	{name: "openai-shaped nulls", frame: `{"type":"inference_response_chunk","request_id":"req-1","data":null,"encrypted_data":null}`, fast: false},
	{name: "extra unknown top-level field", frame: `{"type":"inference_response_chunk","request_id":"req-1","sequence":7,"encrypted_data":{"ephemeral_public_key":"a","ciphertext":"b"}}`, fast: false},
	{name: "extra unknown nested field", frame: `{"type":"inference_response_chunk","request_id":"req-1","encrypted_data":{"ephemeral_public_key":"a","ciphertext":"b","nonce":"c"}}`, fast: false},
	{name: "case-variant key", frame: `{"Type":"inference_response_chunk","request_id":"req-1"}`, fast: false},
	{name: "case-variant nested key", frame: `{"type":"inference_response_chunk","encrypted_data":{"Ciphertext":"b","ephemeral_public_key":"a"}}`, fast: false},
	{name: "duplicate request_id", frame: `{"type":"inference_response_chunk","request_id":"first","request_id":"second"}`, fast: false},
	{name: "duplicate type", frame: `{"type":"inference_response_chunk","type":"inference_response_chunk"}`, fast: false},
	{name: "duplicate nested ciphertext", frame: `{"type":"inference_response_chunk","encrypted_data":{"ciphertext":"a","ciphertext":"b"}}`, fast: false},
	{name: "request_id null", frame: `{"type":"inference_response_chunk","request_id":null}`, fast: false},
	{name: "del byte in string", frame: "{\"type\":\"inference_response_chunk\",\"request_id\":\"a\x7fb\"}", fast: false},
	{name: "not a chunk (heartbeat)", frame: `{"type":"heartbeat","status":"idle"}`, fast: false},
	{name: "not a chunk (accepted, known keys only)", frame: `{"request_id":"req-1","type":"inference_accepted"}`, fast: false},
	{name: "empty object", frame: `{}`, fast: false},

	// --- malformed: fallback (generic decode reports the error) ---
	{name: "truncated", frame: `{"type":"inference_response_chunk","request_id":"req-`, fast: false},
	{name: "truncated after key", frame: `{"type":"inference_response_chunk","request_id"`, fast: false},
	{name: "trailing garbage", frame: `{"type":"inference_response_chunk","request_id":"req-1"} x`, fast: false},
	{name: "two documents", frame: `{"type":"inference_response_chunk"}{"type":"inference_response_chunk"}`, fast: false},
	{name: "trailing comma", frame: `{"type":"inference_response_chunk","request_id":"req-1",}`, fast: false},
	{name: "missing colon", frame: `{"type" "inference_response_chunk"}`, fast: false},
	{name: "missing comma", frame: `{"type":"inference_response_chunk" "request_id":"req-1"}`, fast: false},
	{name: "number request_id", frame: `{"type":"inference_response_chunk","request_id":42}`, fast: false},
	{name: "encrypted_data string", frame: `{"type":"inference_response_chunk","encrypted_data":"nope"}`, fast: false},
	{name: "encrypted_data bad literal", frame: `{"type":"inference_response_chunk","encrypted_data":nullx}`, fast: false},
	{name: "encrypted_data truncated object", frame: `{"type":"inference_response_chunk","encrypted_data":{"ciphertext":"a"`, fast: false},
	{name: "nested trailing comma", frame: `{"type":"inference_response_chunk","encrypted_data":{"ciphertext":"a",}}`, fast: false},
	{name: "control byte in string", frame: "{\"type\":\"inference_response_chunk\",\"request_id\":\"a\tb\"}", fast: false},
	{name: "array document", frame: `[{"type":"inference_response_chunk"}]`, fast: false},
	{name: "bare string", frame: `"inference_response_chunk"`, fast: false},
	{name: "null document", frame: `null`, fast: false},
	{name: "empty input", frame: ``, fast: false},
	{name: "whitespace only", frame: " \n", fast: false},
	{name: "unterminated object", frame: `{"type":"inference_response_chunk"`, fast: false},
}

// TestScanChunkFrameGolden checks every corpus frame two ways: the scanner's
// own result against encoding/json into the concrete struct, and the read
// loop's DecodeProviderMessage against json.Unmarshal into ProviderMessage.
func TestScanChunkFrameGolden(t *testing.T) {
	for _, tc := range chunkFrameCorpus {
		t.Run(tc.name, func(t *testing.T) {
			data := []byte(tc.frame)
			got, ok := scanChunkFrame(data)
			if ok != tc.fast {
				t.Fatalf("scanChunkFrame ok = %v, want %v", ok, tc.fast)
			}
			var want InferenceResponseChunkMessage
			wantErr := json.Unmarshal(data, &want)
			if ok {
				if wantErr != nil {
					t.Fatalf("scanner accepted a frame encoding/json rejects: %v", wantErr)
				}
				if !reflect.DeepEqual(*got, want) {
					t.Fatalf("scanner result differs from encoding/json:\n got  %+v\n want %+v", *got, want)
				}
			}
			assertDecodeProviderMessageEquivalent(t, data)
		})
	}
}

// assertDecodeProviderMessageEquivalent holds the read-loop contract:
// DecodeProviderMessage fails exactly when json.Unmarshal fails and decodes to
// the same message when both succeed.
func assertDecodeProviderMessageEquivalent(t testing.TB, data []byte) {
	t.Helper()
	var generic, direct ProviderMessage
	genericErr := json.Unmarshal(data, &generic)
	directErr := DecodeProviderMessage(data, &direct)
	if (genericErr == nil) != (directErr == nil) {
		t.Fatalf("DecodeProviderMessage err = %v, json.Unmarshal err = %v", directErr, genericErr)
	}
	if genericErr == nil && !reflect.DeepEqual(generic, direct) {
		t.Fatalf("DecodeProviderMessage result differs from json.Unmarshal:\n got  %+v\n want %+v", direct, generic)
	}
}

// TestScanChunkFrameSwiftShapeTakesFastPath is the wire-shape regression
// guard: the exact frame the Swift provider emits (sorted keys, empty data
// omitted, no escapes in base64/UUID) must decode without encoding/json.
func TestScanChunkFrameSwiftShapeTakesFastPath(t *testing.T) {
	frame := swiftShapedChunkFrame(
		"0f3a9c1e-6b7d-4a2e-9c5f-1d2e3f4a5b6c",
		"fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=",
	)
	msg, ok := scanChunkFrame([]byte(frame))
	if !ok {
		t.Fatal("Swift-shaped chunk frame did not take the fast path")
	}
	if msg.RequestID != "0f3a9c1e-6b7d-4a2e-9c5f-1d2e3f4a5b6c" || msg.Data != "" ||
		msg.EncryptedData == nil ||
		msg.EncryptedData.EphemeralPublicKey != "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=" ||
		!strings.HasPrefix(msg.EncryptedData.Ciphertext, "AAECAwQF") {
		t.Fatalf("decoded fields wrong: %+v / %+v", msg, msg.EncryptedData)
	}
	// The Go encoder's key order (type first) is the other shape in the wild
	// (tests, any Go-side tooling); it must be fast too.
	goFrame, err := json.Marshal(InferenceResponseChunkMessage{
		Type:          TypeInferenceResponseChunk,
		RequestID:     "req-1",
		EncryptedData: &EncryptedPayload{EphemeralPublicKey: "a", Ciphertext: "b"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := scanChunkFrame(goFrame); !ok {
		t.Fatal("Go-encoded chunk frame did not take the fast path")
	}
}

// TestScanChunkFrameStructShapeGuard pins the JSON field sets the scanner
// knows about. Adding a field to either struct must come with a scanner
// update — otherwise the new field silently pushes every chunk onto the slow
// path (the scanner bails on unknown keys by design).
func TestScanChunkFrameStructShapeGuard(t *testing.T) {
	assertJSONFields(t, reflect.TypeOf(InferenceResponseChunkMessage{}),
		[]string{"type", "request_id", "data", "encrypted_data"})
	assertJSONFields(t, reflect.TypeOf(EncryptedPayload{}),
		[]string{"ephemeral_public_key", "ciphertext"})
}

func assertJSONFields(t *testing.T, typ reflect.Type, want []string) {
	t.Helper()
	var got []string
	for i := 0; i < typ.NumField(); i++ {
		tag := typ.Field(i).Tag.Get("json")
		name := strings.Split(tag, ",")[0]
		if name == "" || name == "-" {
			t.Fatalf("%s.%s: scanner requires an explicit json name", typ.Name(), typ.Field(i).Name)
		}
		got = append(got, name)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s json fields = %v, want %v — update scanChunkFrame for the new field", typ.Name(), got, want)
	}
}

// TestDecodeProviderMessageChunkAllocs pins the fast path's allocation
// budget: one struct (message + payload) and one shared string.
func TestDecodeProviderMessageChunkAllocs(t *testing.T) {
	frame := benchSwiftChunkFrame()
	allocs := testing.AllocsPerRun(200, func() {
		var pm ProviderMessage
		if err := DecodeProviderMessage(frame, &pm); err != nil {
			t.Fatal(err)
		}
	})
	if allocs > 2 {
		t.Fatalf("chunk fast path allocates %.0f times per frame, want <= 2", allocs)
	}
}

// FuzzChunkFrameDecode holds the scanner to encoding/json: it must never
// panic, whenever it accepts a frame the generic decoder must accept it and
// produce the same message, and the read loop's DecodeProviderMessage must
// succeed exactly when json.Unmarshal does with an identical result.
func FuzzChunkFrameDecode(f *testing.F) {
	for _, tc := range chunkFrameCorpus {
		f.Add([]byte(tc.frame))
	}
	f.Add(benchSwiftChunkFrame())
	f.Add([]byte(`{"type":"heartbeat","status":"idle","note":"say \"hi\""}`))
	f.Add([]byte(`{"type":"inference_complete","request_id":"r","usage":{"prompt_tokens":1,"completion_tokens":2}}`))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 8192 {
			t.Skip()
		}
		got, ok := scanChunkFrame(data)
		if ok {
			var want InferenceResponseChunkMessage
			if err := json.Unmarshal(data, &want); err != nil {
				t.Fatalf("scanner accepted a frame encoding/json rejects (%v): %q", err, data)
			}
			if !reflect.DeepEqual(*got, want) {
				t.Fatalf("scanner result differs from encoding/json for %q:\n got  %+v\n want %+v", data, *got, want)
			}
		}
		assertDecodeProviderMessageEquivalent(t, data)
	})
}
