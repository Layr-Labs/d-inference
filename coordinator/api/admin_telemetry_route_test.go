package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRouteCSVIncludesOutcomeFields(t *testing.T) {
	rec := store.InferenceRouteRecord{
		FinalStatus:            "partial_success",
		ErrorCode:              499,
		ErrorClass:             "client_gone_after_commit_provider_completed",
		PromptTokens:           10,
		CompletionTokens:       20,
		ReasoningTokens:        3,
		CostMicroUSD:           1234,
		ActualTTFTMs:           11.5,
		DispatchToFirstChunkMs: 12.5,
		TotalDurationMs:        99,
		ParseMs:                1,
		ReserveMs:              2,
		RouteMs:                3,
		EncryptMs:              4,
		QueueWaitMs:            5,
		DispatchMs:             6,
		ActualDecodeTPS:        7,
		AdmittedButFailed:      true,
		UsedBackup:             true,
		BackupWon:              true,
	}
	row := routeCSVRow(rec)
	if len(routeCSVHeader) != len(row) {
		t.Fatalf("header cells=%d row cells=%d", len(routeCSVHeader), len(row))
	}
	values := map[string]string{}
	for i, name := range routeCSVHeader {
		values[name] = row[i]
	}
	for _, name := range []string{"final_status", "error_code", "error_class", "prompt_tokens", "completion_tokens", "reasoning_tokens", "cost_micro_usd", "actual_ttft_ms", "dispatch_to_first_chunk_ms", "total_duration_ms", "parse_ms", "reserve_ms", "route_ms", "encrypt_ms", "queue_wait_ms", "dispatch_ms", "actual_decode_tps", "admitted_but_failed", "used_backup", "backup_won"} {
		if _, ok := values[name]; !ok {
			t.Fatalf("route CSV missing %q", name)
		}
	}
	if values["final_status"] != "partial_success" || values["error_code"] != "499" || values["used_backup"] != "true" || values["backup_won"] != "true" {
		t.Fatalf("unexpected CSV outcome values: %+v", values)
	}
}

func TestFilterRouteRecordsByFinalStatus(t *testing.T) {
	records := []store.InferenceRouteRecord{
		{ProviderID: "p1", Model: "m", Outcome: "selected", FinalStatus: "success"},
		{ProviderID: "p2", Model: "m", Outcome: "selected", FinalStatus: "timeout"},
	}
	got := filterRouteRecords(records, "", "", "", "timeout")
	if len(got) != 1 || got[0].ProviderID != "p2" {
		t.Fatalf("filter by final_status returned %+v", got)
	}
}
