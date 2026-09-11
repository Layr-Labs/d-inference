package api

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDefaultMinInputTokensConfig(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want int
	}{{"", 32}, {"0", 0}, {"64", 64}, {"-1", 32}, {"1.5", 32}, {"invalid", 32}, {"2147483648", 32}} {
		t.Run(tc.raw, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_MIN_INPUT_TOKENS", tc.raw)
			if got := ReadServerConfig().DefaultMinInputTokens; got != tc.want {
				t.Fatalf("default=%d want %d", got, tc.want)
			}
		})
	}
}

func TestInputTokenFloorValidation(t *testing.T) {
	for _, value := range []any{0, 32, float64(64), json.Number("32"), json.Number("32.0"), nil} {
		if err := validateInputTokenFloor(map[string]any{minInputTokensParameter: value}); err != nil {
			t.Errorf("valid %#v: %v", value, err)
		}
	}
	for _, value := range []any{-1, -0.5, 1.5, "0", true, []any{0}, map[string]any{}, math.Inf(1), math.NaN(), float64(math.MaxInt32) + 1, json.Number("1e999")} {
		if err := validateInputTokenFloor(map[string]any{minInputTokensParameter: value}); err == nil {
			t.Errorf("invalid %#v accepted", value)
		}
	}
}

func TestRejectShortInputBoundaryAndOverrides(t *testing.T) {
	srv := &Server{defaultMinInputTokens: 32}
	for _, tc := range []struct {
		name       string
		tokens     int
		parameters map[string]any
		rejected   bool
	}{
		{"below default", 31, nil, true}, {"at default", 32, nil, false}, {"above default", 33, nil, false},
		{"testing disabled", 1, map[string]any{"min_input_tokens": 0}, false},
		{"model lower", 8, map[string]any{"min_input_tokens": float64(8)}, false},
		{"model higher", 32, map[string]any{"min_input_tokens": 64}, true},
		{"null inherits", 31, map[string]any{"min_input_tokens": nil}, true},
		{"invalid legacy inherits", 31, map[string]any{"min_input_tokens": -1}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			parsed := map[string]any{"min_input_tokens": 0, "runtime_parameters": map[string]any{"min_input_tokens": 0}}
			if got := srv.rejectShortInput(w, r, parsed, "public-model", "build", tc.tokens, tc.parameters); got != tc.rejected {
				t.Fatalf("rejected=%v want %v", got, tc.rejected)
			}
			if tc.rejected && (w.Code != 400 || !strings.Contains(w.Body.String(), `"code":"input_too_short"`) || !strings.Contains(w.Body.String(), `"type":"invalid_request_error"`)) {
				t.Fatalf("wrong error: %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestInputTokenFloorRegistrationValidation(t *testing.T) {
	req := registerModelRequest{ModelID: "test-model", Version: "v1", Quantization: "4bit", MaxContextLength: 1024, MaxOutputLength: 128, MinRAMGB: 1, InputPrice: 1, OutputPrice: 1}
	for _, v := range []any{nil, 0, 32, 1.5, -1, "0"} {
		req.RuntimeParameters = map[string]any{minInputTokensParameter: v}
		err := validateRegisterModelRequest(req)
		valid := v == nil || v == 0 || v == 32
		if (err == nil) != valid {
			t.Errorf("value %#v: %v", v, err)
		}
	}
}
