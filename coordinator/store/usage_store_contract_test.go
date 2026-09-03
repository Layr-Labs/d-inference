package store

import "testing"

func TestRecordUsage(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			s.RecordUsage("provider-1", "consumer-key", "qwen3.5-9b", 50, 100)
			s.RecordUsage("provider-2", "consumer-key", "llama-3", 30, 200)

			records := s.UsageRecords()
			if len(records) != 2 {
				t.Fatalf("usage records = %d, want 2", len(records))
			}

			// Row order is backend-specific for same-timestamp inserts; find by
			// provider.
			var r *UsageRecord
			for i := range records {
				if records[i].ProviderID == "provider-1" {
					r = &records[i]
					break
				}
			}
			if r == nil {
				t.Fatalf("provider-1 usage record missing: %+v", records)
			}
			// Memory stores the raw consumer key; postgres stores its hash. Both
			// must attribute the record to some consumer identity.
			if r.ConsumerKey == "" {
				t.Error("consumer_key should not be empty")
			}
			if name == "memory" && r.ConsumerKey != "consumer-key" {
				t.Errorf("consumer_key = %q, want raw key on memory store", r.ConsumerKey)
			}
			if r.Model != "qwen3.5-9b" {
				t.Errorf("model = %q", r.Model)
			}
			if r.PromptTokens != 50 {
				t.Errorf("prompt_tokens = %d", r.PromptTokens)
			}
			if r.CompletionTokens != 100 {
				t.Errorf("completion_tokens = %d", r.CompletionTokens)
			}
			if r.Timestamp.IsZero() {
				t.Error("timestamp should not be zero")
			}
		})
	}
}
func TestUsageRecordsEmpty(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			records := s.UsageRecords()
			if len(records) != 0 {
				t.Errorf("usage records = %d, want 0", len(records))
			}
		})
	}
}
func TestUsagePublicModelStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			st.RecordUsageFullWithPublicModel(
				"provider-1", "consumer-key", "key-1", "build-v1", "public-alias",
				uniqueID("request"), 50, 100, 123, nil,
			)
			records := st.UsageRecords()
			if len(records) != 1 {
				t.Fatalf("usage records = %d, want 1", len(records))
			}
			if records[0].Model != "build-v1" || records[0].PublicModel != "public-alias" {
				t.Fatalf("usage model attribution mismatch: %+v", records[0])
			}
			records[0].PromptTokens = 999
			if original := st.UsageRecords(); original[0].PromptTokens != 50 {
				t.Fatal("UsageRecords returned mutable store state")
			}
		})
	}
}
