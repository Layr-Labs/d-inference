package e2e

import (
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

func batchControlEvents(cache string) []testbed.ProviderWireEvent {
	raw := func(v string) json.RawMessage { return json.RawMessage(v) }
	var events []testbed.ProviderWireEvent
	for _, id := range []string{"first", "second"} {
		scope, usage := "false", `{"prompt_tokens":8192,"completion_tokens":128}`
		if cache == "ssd" {
			scope, usage = "true", `{"prompt_tokens":8192,"completion_tokens":128,"cached_tokens":6144,"prefill_tokens_saved":6144,"cache_outcome":"hit","cache_tier":"ssd"}`
		}
		events = append(events, testbed.ProviderWireEvent{RequestID: id, Type: "inference_request", Fields: map[string]json.RawMessage{
			"encrypted_body_present": raw("true"), "cache_scope_present": raw(scope),
			"cache_receipt_nonce_present": raw(scope), "cache_receipt_boundary_mode": raw(`"checkpoint"`),
		}})
		if cache == "ssd" {
			events = append(events, testbed.ProviderWireEvent{RequestID: id, Type: "prefix_cache_lookup_v2", Fields: map[string]json.RawMessage{"outcome": raw(`"hit"`)}})
		}
		events = append(events, testbed.ProviderWireEvent{RequestID: id, Type: "inference_complete", Fields: map[string]json.RawMessage{
			"profile": raw(`{"mtp_active":false,"engine":{"batch_rows_max":2}}`), "usage": raw(usage),
		}})
	}
	return events
}

func TestConnectedBatchEvidenceRejectsPartialOrSerialSuccess(t *testing.T) {
	for _, mode := range []string{"off", "ssd"} {
		require.NoError(t, validateConnectedBatchWire(batchControlEvents(mode), mode))
	}
	for name, change := range map[string]func([]testbed.ProviderWireEvent) []testbed.ProviderWireEvent{
		"missing_second_request": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent { return v[:3] },
		"missing_terminal":       func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent { return v[:len(v)-1] },
		"serial_rows_only": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			for i := range v {
				if v[i].Type == "inference_complete" {
					v[i].Fields["profile"] = json.RawMessage(`{"mtp_active":false,"engine":{"batch_rows_max":1}}`)
				}
			}
			return v
		},
		"missing_batch_profile": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			delete(v[2].Fields, "profile")
			return v
		},
		"no_terminal_adoption": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			v[2].Fields["usage"] = json.RawMessage(`{"prompt_tokens":8192,"completion_tokens":128}`)
			return v
		},
		"missing_attempt_nonce": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			delete(v[0].Fields, "cache_receipt_nonce_present")
			return v
		},
		"missing_scope": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			v[0].Fields["cache_scope_present"] = json.RawMessage("false")
			return v
		},
		"unencrypted": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			v[0].Fields["encrypted_body_present"] = json.RawMessage("false")
			return v
		},
		"duplicate_terminal": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent { return append(v, v[2]) },
		"provider_error": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			v[2].Type = "inference_error"
			return v
		},
		"wrong_mtp": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			v[2].Fields["profile"] = json.RawMessage(`{"mtp_active":true,"engine":{"batch_rows_max":2}}`)
			return v
		},
		"lookup_miss": func(v []testbed.ProviderWireEvent) []testbed.ProviderWireEvent {
			v[1].Fields["outcome"] = json.RawMessage(`"miss_absent"`)
			return v
		},
	} {
		t.Run(name, func(t *testing.T) {
			require.Error(t, validateConnectedBatchWire(change(batchControlEvents("ssd")), "ssd"))
		})
	}
}

func TestConnectedBatchUsageRetainsReasoningAndOtherDetails(t *testing.T) {
	baseline := json.RawMessage(`{"prompt_tokens":8192,"completion_tokens":128,"total_tokens":8320,"completion_tokens_details":{"reasoning_tokens":60}}`)
	warm := json.RawMessage(`{"prompt_tokens":8192,"completion_tokens":128,"total_tokens":8320,"completion_tokens_details":{"reasoning_tokens":60},"prompt_tokens_details":{"cached_tokens":6144}}`)
	require.NoError(t, validateConnectedBatchUsage(baseline, warm))
	for _, changed := range []json.RawMessage{
		json.RawMessage(`{"prompt_tokens":8192,"completion_tokens":128,"total_tokens":8320,"completion_tokens_details":{"reasoning_tokens":59}}`),
		json.RawMessage(`{"prompt_tokens":8192,"completion_tokens":128,"total_tokens":8320}`),
		json.RawMessage(`{"prompt_tokens":8192,"completion_tokens":128,"total_tokens":8320,"completion_tokens_details":{"reasoning_tokens":60},"prompt_tokens_details":{"cached_tokens":6144,"unexpected":1}}`),
		json.RawMessage(`null`),
		json.RawMessage(`{"prompt_tokens_details":null}`),
	} {
		require.Error(t, validateConnectedBatchUsage(baseline, changed))
	}
}
