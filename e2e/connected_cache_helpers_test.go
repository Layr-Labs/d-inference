package e2e

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

func TestConnectedSSEToolFragmentsAndUsage(t *testing.T) {
	var out connectedStream
	for _, line := range []string{
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"tool-1","function":{"name":"record_color","arguments":"{\"color\":"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"blue\",\"count\":2}"}}]},"finish_reason":"tool_calls"}]}`,
		`data: {"choices":[],"usage":{"completion_tokens":7}}`, `data: [DONE]`,
	} {
		_, err := out.acceptSSE([]byte(line))
		require.NoError(t, err)
	}
	require.True(t, out.Done)
	require.Equal(t, "tool_calls", out.Finish)
	require.JSONEq(t, `{"color":"blue","count":2}`, out.Tools[0].Arguments)
	require.Equal(t, "record_color", out.Tools[0].Name)
	require.JSONEq(t, `{"completion_tokens":7}`, string(out.Usage))
}
func syntheticConnectedRow() connectedCase {
	field := func(raw string) map[string]json.RawMessage {
		var out map[string]json.RawMessage
		_ = json.Unmarshal([]byte(raw), &out)
		return out
	}
	row := connectedCase{HTTP: connectedStream{Done: true, Finish: "stop", Content: "blue"}, Wire: []testbed.ProviderWireEvent{
		{Connection: 1, Type: "inference_request", RequestID: "r", Fields: field(`{"encrypted_body_present":true,"cache_scope_present":true,"cache_receipt_boundary_mode":"checkpoint"}`)},
		{Connection: 1, Type: "prefix_cache_lookup_v2", RequestID: "r", Fields: field(`{"matched_anchor_tokens":1024}`)},
		{Connection: 1, Type: "inference_complete", RequestID: "r", Fields: field(`{"usage":{"completion_tokens":7,"cached_tokens":1024,"prefill_tokens_saved":1024,"cache_outcome":"hit","cache_tier":"ssd"},"profile":{"mtp_active":true}}`)},
	}}
	row.After.Lifecycle.SSDLookups = 1
	row.After.Lifecycle.SSDHits = 1
	return row
}
func TestConnectedEvidenceRequiresAcceptedActualHit(t *testing.T) {
	row := syntheticConnectedRow()
	require.NoError(t, validateConnectedCase(row, "ssd", "on", "hit"))
	for _, test := range []struct {
		name   string
		mutate func(*connectedCase)
	}{
		{"wire receipt alone", func(r *connectedCase) { r.After.Lifecycle.SSDHits = 0 }},
		{"missing accepted lookup", func(r *connectedCase) { r.After.Lifecycle.SSDLookups = 0 }},
		{"no checkpoint echo", func(r *connectedCase) { delete(r.Wire[0].Fields, "cache_receipt_boundary_mode") }},
		{"plaintext dispatch", func(r *connectedCase) { r.Wire[0].Fields["encrypted_body_present"] = json.RawMessage("false") }},
		{"missing MTP proof", func(r *connectedCase) { delete(r.Wire[2].Fields, "profile") }},
		{"wrong terminal request", func(r *connectedCase) { r.Wire[2].RequestID = "other" }},
		{"read is not adoption", func(r *connectedCase) {
			r.Wire[2].Fields["usage"] = json.RawMessage(`{"completion_tokens":7,"cached_tokens":1024,"prefill_tokens_saved":0,"cache_outcome":"hit","cache_tier":"ssd"}`)
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			r := syntheticConnectedRow()
			test.mutate(&r)
			require.Error(t, validateConnectedCase(r, "ssd", "on", "hit"))
		})
	}
}
func TestConnectedCancellationDoesNotCreditFastFinish(t *testing.T) {
	row := syntheticConnectedRow()
	row.Wire = append(row.Wire, testbed.ProviderWireEvent{Type: "cancel", RequestID: "r"})
	require.Error(t, validateConnectedCase(row, "ssd", "on", "cancel"))
	row.HTTP.CancelledByClient = true
	row.HTTP.Done = false
	// Even an observed cancel after a successful terminal is not retirement proof.
	require.Error(t, validateConnectedCase(row, "ssd", "on", "cancel"))
	row.Wire[2] = testbed.ProviderWireEvent{Type: "inference_error", RequestID: "r", Fields: map[string]json.RawMessage{"terminal_cause": json.RawMessage(`"cancelled"`)}}
	require.Error(t, validateConnectedCase(row, "ssd", "on", "cancel"), "error terminal lacks actual restored usage/MTP evidence")
}
func TestConnectedBranchNeedsSameProviderHistoricalReady(t *testing.T) {
	row := syntheticConnectedRow()
	ready := connectedCase{Wire: []testbed.ProviderWireEvent{{Connection: 1, Type: "prefix_cache_ready_v2", Fields: map[string]json.RawMessage{"ready_positions": json.RawMessage(`[2048,4096]`)}}}}
	require.Error(t, validateConnectedBranch(row, []connectedCase{ready}))
	ready.Wire[0].Fields["ready_positions"] = json.RawMessage(`[1024,2048]`)
	require.NoError(t, validateConnectedBranch(row, []connectedCase{ready}))
	ready.Wire[0].Connection = 2
	require.Error(t, validateConnectedBranch(row, []connectedCase{ready}))
}
func TestConnectedInputRejectsArtifactSubstitutionAndMTPBypass(t *testing.T) {
	for _, in := range []connectedCacheInput{
		{Backend: "auto"},
		{Backend: "paged", CacheMode: "resident"},
		{Backend: "paged", CacheMode: "ssd", MaxConcurrent: 1},
	} {
		_, err := in.validate()
		require.Error(t, err)
	}
	in := connectedCacheInput{Backend: "paged", CacheMode: "ssd", MaxConcurrent: 1, MTPMode: "off", Prompt: strings.Repeat("prefix ", 1024), ToolsRequest: json.RawMessage(`{}`)}
	in.Artifact.ModelID = "gemma-4-26b"
	_, err := in.validate()
	require.ErrorContains(t, err, "normal MTP")
	in.MTPMode = "on"
	_, err = in.validate()
	require.ErrorContains(t, err, "assistant")
	in.Artifact.ModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
	_, err = in.validate()
	require.ErrorContains(t, err, "exact release model")
}

func TestConnectedCancellationPartialSettlementNeedsAbortedProfile(t *testing.T) {
	row := syntheticConnectedRow()
	row.HTTP.Done = false
	row.HTTP.CancelledByClient = true
	row.Wire = append(row.Wire, testbed.ProviderWireEvent{Type: "cancel", RequestID: "r"})
	row.Wire[2].Fields["profile"] = json.RawMessage(`{"mtp_active":true,"cancel_received_us":200,"cancel_aborted_us":240}`)
	require.NoError(t, validateConnectedCase(row, "ssd", "on", "cancel"))
	row.Wire[2].Fields["profile"] = json.RawMessage(`{"mtp_active":true,"cancel_received_us":200}`)
	require.Error(t, validateConnectedCase(row, "ssd", "on", "cancel"))
	row.Wire[2].Fields["profile"] = json.RawMessage(`{"mtp_active":true,"cancel_received_us":200,"cancel_aborted_us":100}`)
	require.Error(t, validateConnectedCase(row, "ssd", "on", "cancel"))
}
func TestConnectedHTTPWinnerMustMatchRoutingHint(t *testing.T) {
	row := syntheticConnectedRow()
	row.HTTP.ProviderID = "provider-a"
	routes := []map[string]any{{"request_id": "r", "winner": "provider-a", "cache_tier": "ssd"}}
	require.NoError(t, validateConnectedRoute(row, routes, "ssd", "hit"))
	routes[0]["winner"] = "provider-b"
	require.Error(t, validateConnectedRoute(row, routes, "ssd", "hit"))
	routes[0]["winner"] = "provider-a"
	routes[0]["cache_tier"] = ""
	require.Error(t, validateConnectedRoute(row, routes, "ssd", "hit"))
}

func TestConnectedReasoningOnlyCompletionIsRetained(t *testing.T) {
	var out connectedStream
	content, err := out.acceptSSE([]byte(`data: {"choices":[{"delta":{"reasoning_content":"reasoning-only response"},"finish_reason":"length"}]}`))
	require.NoError(t, err)
	require.True(t, content)
	require.Empty(t, out.Content)
	require.Equal(t, "reasoning-only response", out.Reasoning)
	row := syntheticConnectedRow()
	row.HTTP.Content = ""
	row.HTTP.Reasoning = out.Reasoning
	row.HTTP.Finish = "length"
	require.NoError(t, validateConnectedCase(row, "ssd", "on", "hit"))
}
