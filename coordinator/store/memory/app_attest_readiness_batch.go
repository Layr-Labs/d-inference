package memory

import (
	"context"
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

func (s *MemoryStore) GetAppAttestReadinessBatch(ctx context.Context, keys []string) (map[string]store.AppAttestReadiness, error) {
	keys, err := shared.ReadinessBatchKeys(keys)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]store.AppAttestReadiness, len(keys))
	for _, key := range keys {
		if _, exists := s.appAttestShadowKeys[key]; exists {
			out[key] = store.AppAttestReadiness{Revoked: s.appAttestRevocations[key]}
		}
	}
	for _, evidence := range s.appAttestEvidence {
		receipt := evidence.Decision.Receipt
		if receipt == nil || receipt.Outcome != "verified" {
			continue
		}
		current, exists := out[receipt.KeyID]
		if !exists || current.Receipt != nil && (current.Receipt.ReceivedAt.After(receipt.ReceivedAt) || current.Receipt.ReceivedAt.Equal(receipt.ReceivedAt) && current.Receipt.ID >= receipt.ID) {
			continue
		}
		// Match the PostgreSQL projection; evidence bodies are not needed in the
		// serving snapshot and remain in the private evidence archive.
		current.Receipt = &store.AppAttestReceipt{ID: receipt.ID, KeyID: receipt.KeyID, Outcome: receipt.Outcome,
			Details: append(json.RawMessage(nil), receipt.Details...), ReceivedAt: receipt.ReceivedAt,
			ExpiresAt: receipt.ExpiresAt, NextAt: receipt.NextAt}
		out[receipt.KeyID] = current
	}
	return out, nil
}

var _ store.AppAttestReadinessBatchStore = (*MemoryStore)(nil)
