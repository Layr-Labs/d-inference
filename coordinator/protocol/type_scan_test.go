package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// TestScanTopLevelString pins the scanner's behavior: it must return the
// correct value whenever it reports ok=true, and report ok=false on anything
// it cannot be 100% sure about so callers fall back to encoding/json.
func TestScanTopLevelString(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
		ok   bool
		// skipReference disables the encoding/json cross-check for cases
		// where the scanner intentionally diverges (duplicate keys).
		skipReference bool
	}{
		// --- success cases ---
		{name: "type first key", in: `{"type":"heartbeat","status":"idle"}`, want: "heartbeat", ok: true},
		{name: "type only key", in: `{"type":"register"}`, want: "register", ok: true},
		{
			name: "type last key after nested decoys",
			in:   `{"stats":{"type":"decoy","n":1},"models":[{"type":"inner"},["type",2]],"type":"register"}`,
			want: "register", ok: true,
		},
		{
			name: "type-looking strings inside arrays are skipped",
			in:   `{"warm_models":["type","typewriter"],"type":"heartbeat"}`,
			want: "heartbeat", ok: true,
		},
		{
			name: "numbers bools null floats exponents skipped",
			in:   `{"a":1,"b":-2.5,"c":1e10,"d":2.5E-3,"e":true,"f":false,"g":null,"type":"heartbeat"}`,
			want: "heartbeat", ok: true,
		},
		{
			name: "whitespace variants",
			in:   " \t\r\n{ \"a\" : 1 ,\n\t\"type\" :\r\"heartbeat\" , \"b\" : [ 1 , 2 ] }",
			want: "heartbeat", ok: true,
		},
		// Escapes inside a *skipped* value are handled by skipJSONString, so
		// the scan still succeeds (and must agree with encoding/json).
		{
			name: "escaped string value before type is skipped correctly",
			in:   `{"note":"say \"hi\" \\ done","type":"heartbeat"}`,
			want: "heartbeat", ok: true,
		},
		// --- conservative fallback cases (ok=false => envelope decode) ---
		{name: "escaped key before type falls back", in: `{"no\u0074e":1,"type":"heartbeat"}`, ok: false},
		{name: "escaped type value falls back", in: `{"type":"heart\u0062eat"}`, ok: false},
		{name: "non-string type number", in: `{"type":123}`, ok: false},
		{name: "non-string type float", in: `{"type":1.5e3}`, ok: false},
		{name: "non-string type bool", in: `{"type":true}`, ok: false},
		{name: "non-string type null", in: `{"type":null}`, ok: false},
		{name: "non-string type object", in: `{"type":{"x":1}}`, ok: false},
		{name: "non-string type array", in: `{"type":["heartbeat"]}`, ok: false},
		{name: "missing type", in: `{"status":"idle"}`, ok: false},
		{name: "empty object", in: `{}`, ok: false},
		{name: "empty input", in: ``, ok: false},
		{name: "truncated mid key", in: `{"typ`, ok: false},
		{name: "truncated before value", in: `{"type":`, ok: false},
		{name: "truncated mid value", in: `{"type":"heartb`, ok: false},
		{name: "truncated after first pair", in: `{"a":1,`, ok: false},
		{name: "top-level array", in: `["type","heartbeat"]`, ok: false},
		{name: "top-level string", in: `"type"`, ok: false},
		{name: "top-level null", in: `null`, ok: false},
		// The scanner is first-wins on duplicate keys while encoding/json is
		// last-wins. Our providers never emit duplicate keys, so this
		// divergence is acceptable; the case documents the behavior.
		{
			name: "duplicate type keys takes first",
			in:   `{"type":"first","type":"second"}`,
			want: "first", ok: true, skipReference: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := scanTopLevelString([]byte(tc.in), "type")
			if ok != tc.ok || got != tc.want {
				t.Fatalf("scanTopLevelString(%q) = (%q, %v), want (%q, %v)", tc.in, got, ok, tc.want, tc.ok)
			}
			if !ok || tc.skipReference {
				return
			}
			// Never-wrong invariant: whenever the scanner reports success it
			// must agree with the envelope decode it replaces.
			var envelope struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal([]byte(tc.in), &envelope); err != nil {
				t.Fatalf("scanner returned ok=true but reference decode failed: %v", err)
			}
			if envelope.Type != got {
				t.Fatalf("scanner returned %q but envelope decode returned %q", got, envelope.Type)
			}
		})
	}
}

// TestProviderMessageUnmarshalScanEquivalence round-trips a corpus of real
// provider messages and asserts the fast-path decode is indistinguishable
// from the old double-parse: same envelope type, same Type field, same
// concrete payload type.
func TestProviderMessageUnmarshalScanEquivalence(t *testing.T) {
	activeModel := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	hb := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "idle",
		Stats: HeartbeatStats{
			RequestsServed:  1523,
			TokensGenerated: 4_892_310,
		},
		WarmModels: []string{
			"mlx-community/Qwen3.5-9B-Instruct-4bit",
			"mlx-community/Trinity-Mini-8bit",
		},
		SystemMetrics: SystemMetrics{
			MemoryPressure: 0.35,
			CPUUsage:       0.22,
			ThermalState:   "nominal",
		},
	}
	hb.ActiveModel = &activeModel

	corpus := []struct {
		name        string
		msg         any
		wantType    string
		wantPayload any
	}{
		{
			name:        "heartbeat",
			msg:         hb,
			wantType:    TypeHeartbeat,
			wantPayload: &HeartbeatMessage{},
		},
		{
			name: "encrypted response chunk",
			msg: InferenceResponseChunkMessage{
				Type:      TypeInferenceResponseChunk,
				RequestID: "req-abc123-def456-789012",
				EncryptedData: &EncryptedPayload{
					EphemeralPublicKey: "dGVzdC1lcGhlbWVyYWwtcHVibGljLWtleS0zMi1ieXRlcw==",
					Ciphertext:         "bm9uY2UtMjQtYnl0ZXMtaGVyZS4uLi5lbmNyeXB0ZWQtcGF5bG9hZC1kYXRhLXRoYXQtaXMtcXVpdGUtbG9uZy1mb3ItcmVhbGlzdGljLWJlbmNobWFyaw==",
				},
			},
			wantType:    TypeInferenceResponseChunk,
			wantPayload: &InferenceResponseChunkMessage{},
		},
		{
			// Plaintext SSE chunk: Data contains quotes that json.Marshal
			// escapes, exercising escape handling in skipped values.
			name: "plaintext response chunk",
			msg: InferenceResponseChunkMessage{
				Type:      TypeInferenceResponseChunk,
				RequestID: "req-abc123-def456-789012",
				Data:      `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"hi"}}]}` + "\n\n",
			},
			wantType:    TypeInferenceResponseChunk,
			wantPayload: &InferenceResponseChunkMessage{},
		},
		{
			name: "register",
			msg: RegisterMessage{
				Type: TypeRegister,
				Hardware: Hardware{
					MachineModel:       "Mac15,8",
					ChipName:           "Apple M3 Max",
					ChipFamily:         "M3",
					ChipTier:           "Max",
					MemoryGB:           64,
					MemoryAvailableGB:  58.5,
					CPUCores:           CPUCores{Total: 16, Performance: 12, Efficiency: 4},
					GPUCores:           40,
					MemoryBandwidthGBs: 400,
				},
				Models: []ModelInfo{
					{ID: "mlx-community/Qwen3.5-9B-Instruct-4bit", SizeBytes: 5_700_000_000, ModelType: "qwen3", Quantization: "4bit"},
					{ID: "mlx-community/Trinity-Mini-8bit", SizeBytes: 14_200_000_000, ModelType: "qwen2_moe", Quantization: "8bit"},
				},
				Backend:    "vllm_mlx",
				PublicKey:  "dGVzdC1wdWJsaWMta2V5LWJhc2U2NC1lbmNvZGVk",
				PrefillTPS: 210.5,
				DecodeTPS:  55.3,
			},
			wantType:    TypeRegister,
			wantPayload: &RegisterMessage{},
		},
		{
			name: "inference error",
			msg: InferenceErrorMessage{
				Type:        TypeInferenceError,
				RequestID:   "req-abc123-def456-789012",
				Error:       `model "mlx-community/Qwen3.5-9B-Instruct-4bit" not loaded`,
				StatusCode:  503,
				ErrorReason: "model_not_loaded",
			},
			wantType:    TypeInferenceError,
			wantPayload: &InferenceErrorMessage{},
		},
	}

	for _, tc := range corpus {
		t.Run(tc.name, func(t *testing.T) {
			data, err := json.Marshal(tc.msg)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}

			// Reference: the old envelope decode.
			var envelope struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(data, &envelope); err != nil {
				t.Fatalf("envelope decode: %v", err)
			}

			// The fast-path scanner must find the same type.
			scanned, ok := scanTopLevelString(data, "type")
			if !ok {
				t.Fatalf("scanTopLevelString did not take the fast path for %s", data)
			}
			if scanned != envelope.Type {
				t.Fatalf("scanTopLevelString = %q, envelope decode = %q", scanned, envelope.Type)
			}

			// Full decode must produce the same Type and payload type as before.
			var pm ProviderMessage
			if err := pm.UnmarshalJSON(data); err != nil {
				t.Fatalf("UnmarshalJSON: %v", err)
			}
			if pm.Type != tc.wantType {
				t.Fatalf("pm.Type = %q, want %q", pm.Type, tc.wantType)
			}
			if got, want := reflect.TypeOf(pm.Payload), reflect.TypeOf(tc.wantPayload); got != want {
				t.Fatalf("payload type = %v, want %v", got, want)
			}
		})
	}
}

// TestScanTopLevelStringAdversarialNoPanic feeds hostile and malformed inputs
// through both the scanner and the full UnmarshalJSON path. Errors are fine;
// panics are not.
func TestScanTopLevelStringAdversarialNoPanic(t *testing.T) {
	inputs := []string{
		"", "{", "}", "{{{{", "[[[[", `{"`, `{"a`, `{"a"`, `{"a":`, `{"a":}`,
		`{"a":"`, `{"a":"\`, `{"a":"\\`, `{"a":"\"`, `{:1}`, `{1:2}`,
		`{"type"`, `{"type":`, `{"type":"`, `{"type":"x`, `{"type":"x"`,
		`{"type" "x"}`, `{"a":1"b":2}`, `{"a":1,,"type":"x"}`,
		`{"a":[}],"type":"x"}`, `{"a":{]},"type":"x"}`,
		`{"a":truefalse,"type":"x"}`, `{"a":nul}`, `{"a":-,"type":"x"}`,
		`{"a":"\u12"}`, `{,}`, `{"":""}`, `{"type":""}`,
		"\x00\x01\x02", "\xff\xfe{\"type\":\"x\"}",
		`{"type":"x"}garbage`, `{"a":"b"} {"type":"x"}`,
		strings.Repeat(`{"a":`, 1000) + `1` + strings.Repeat(`}`, 1000),
		strings.Repeat("[", 10000),
		strings.Repeat(`\`, 4096),
		`{"a":"` + strings.Repeat(`\`, 4095) + `"}`,
	}

	for _, in := range inputs {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("panic on input %q: %v", in, r)
				}
			}()
			_, _ = scanTopLevelString([]byte(in), "type")
			var pm ProviderMessage
			_ = pm.UnmarshalJSON([]byte(in))
		}()
	}
}
