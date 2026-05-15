package api

import (
	"encoding/json"
	"testing"
)

func TestErrorResponse_CodeField(t *testing.T) {
	// errorResponse always sets code, defaulting to errType.
	resp := errorResponse("invalid_request_error", "bad input")
	detail := resp["error"].(map[string]any)

	if code, _ := detail["code"].(string); code != "invalid_request_error" {
		t.Errorf("default code = %q, want %q", code, "invalid_request_error")
	}
	if _, ok := detail["param"]; ok {
		t.Error("param should be absent when not set")
	}
}

func TestErrorResponse_WithCode(t *testing.T) {
	resp := errorResponse("insufficient_funds", "low balance", withCode("insufficient_quota"))
	detail := resp["error"].(map[string]any)

	if code, _ := detail["code"].(string); code != "insufficient_quota" {
		t.Errorf("code = %q, want %q", code, "insufficient_quota")
	}
}

func TestErrorResponse_WithParam(t *testing.T) {
	resp := errorResponse("invalid_request_error", "model is required", withParam("model"))
	detail := resp["error"].(map[string]any)

	if param, _ := detail["param"].(string); param != "model" {
		t.Errorf("param = %q, want %q", param, "model")
	}
}

func TestErrorResponse_WithCodeAndParam(t *testing.T) {
	resp := errorResponse("model_not_found", "not found", withCode("model_not_found"), withParam("model"))
	detail := resp["error"].(map[string]any)

	if code, _ := detail["code"].(string); code != "model_not_found" {
		t.Errorf("code = %q, want %q", code, "model_not_found")
	}
	if param, _ := detail["param"].(string); param != "model" {
		t.Errorf("param = %q, want %q", param, "model")
	}
}

func TestErrorResponse_JSONSerialization(t *testing.T) {
	// Verify the output matches OpenAI error shape.
	resp := errorResponse("invalid_request_error", "model is required", withParam("model"), withCode("invalid_request_error"))
	b, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var parsed struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
			Code    string `json:"code"`
			Param   string `json:"param"`
		} `json:"error"`
	}
	if err := json.Unmarshal(b, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if parsed.Error.Code != "invalid_request_error" {
		t.Errorf("code = %q, want %q", parsed.Error.Code, "invalid_request_error")
	}
	if parsed.Error.Param != "model" {
		t.Errorf("param = %q, want %q", parsed.Error.Param, "model")
	}
}

func TestErrorResponse_CodeDefaultsToType(t *testing.T) {
	// All existing call sites that don't pass withCode() should still get
	// a code field that mirrors the type — this is the backward-compatible default.
	resp := errorResponse("internal_error", "something broke")
	detail := resp["error"].(map[string]any)

	if code, _ := detail["code"].(string); code != "internal_error" {
		t.Errorf("code = %q, want %q", code, "internal_error")
	}
}

func TestErrorResponse_InsufficientFundsUsesCanonicalCode(t *testing.T) {
	// insufficient_funds type must use the OpenAI-canonical code "insufficient_quota".
	resp := errorResponse("insufficient_funds", "low balance", withCode("insufficient_quota"))
	detail := resp["error"].(map[string]any)

	if code, _ := detail["code"].(string); code != "insufficient_quota" {
		t.Errorf("code = %q, want %q", code, "insufficient_quota")
	}
	if typ, _ := detail["type"].(string); typ != "insufficient_funds" {
		t.Errorf("type = %q, want %q", typ, "insufficient_funds")
	}
}
