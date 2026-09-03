package store

import "testing"

func TestRecordPayment(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "test payment")
			if err != nil {
				t.Fatalf("RecordPayment: %v", err)
			}
		})
	}
}
func TestRecordPaymentDuplicateTxHash(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
			if err != nil {
				t.Fatalf("first RecordPayment: %v", err)
			}

			err = s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
			if err == nil {
				t.Error("expected error for duplicate tx_hash")
			}
		})
	}
}
