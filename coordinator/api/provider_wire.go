package api

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

var errFirstContentDeadlineAtWriter = errors.New(errFirstContentDeadlineExpired)

type providerInferenceFrameSnapshot struct {
	requestID            string
	ephemeralPublicKey   string
	ciphertext           string
	firstContentBudgetMS int64
	firstContentDeadline time.Time
	cacheReceiptNonce    string
	cacheScope           string
	prefixCacheProtocol  int
}

func snapshotProviderInferenceFrame(
	requestID, ephemeralPublicKey, ciphertext string,
	pr *registry.PendingRequest,
) providerInferenceFrameSnapshot {
	snapshot := providerInferenceFrameSnapshot{
		requestID:          requestID,
		ephemeralPublicKey: ephemeralPublicKey,
		ciphertext:         ciphertext,
	}
	if pr == nil {
		return snapshot
	}
	snapshot.firstContentBudgetMS = pr.FirstContentBudgetMS
	snapshot.firstContentDeadline = pr.FirstContentDeadline
	snapshot.cacheReceiptNonce = pr.CacheReceiptNonce
	snapshot.cacheScope = pr.CacheScope
	snapshot.prefixCacheProtocol = pr.PrefixCacheProtocol
	return snapshot
}

func (snapshot providerInferenceFrameSnapshot) wireMessage(
	firstContentBudgetMS int64,
) protocol.InferenceRequestMessage {
	message := protocol.InferenceRequestMessage{
		Type:                       protocol.TypeInferenceRequest,
		RequestID:                  snapshot.requestID,
		ToolSchemaMetadataProtocol: 1,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: snapshot.ephemeralPublicKey,
			Ciphertext:         snapshot.ciphertext,
		},
	}
	if firstContentBudgetMS > 0 {
		message.FirstContentBudgetMS = firstContentBudgetMS
	}
	if snapshot.cacheReceiptNonce == "" || snapshot.cacheScope == "" {
		return message
	}
	message.CacheReceiptNonce = snapshot.cacheReceiptNonce
	message.CacheScope = snapshot.cacheScope
	if snapshot.prefixCacheProtocol > 0 {
		message.PrefixCacheProtocol = snapshot.prefixCacheProtocol
	}
	return message
}

func providerInferenceWireMessage(
	requestID, ephemeralPublicKey, ciphertext string,
	pr *registry.PendingRequest,
) protocol.InferenceRequestMessage {
	snapshot := snapshotProviderInferenceFrame(
		requestID, ephemeralPublicKey, ciphertext, pr)
	return snapshot.wireMessage(snapshot.firstContentBudgetMS)
}

// providerInferenceFrameBuilder defers the deadline-sensitive outer frame until
// the request reaches the head of the provider's data lane. Encryption and
// cache preparation are already complete; only the remaining budget and JSON
// envelope are produced here.
func providerInferenceFrameBuilder(
	requestID, ephemeralPublicKey, ciphertext string,
	pr *registry.PendingRequest,
) registry.TextFrameBuilder {
	snapshot := snapshotProviderInferenceFrame(
		requestID, ephemeralPublicKey, ciphertext, pr)
	return func(dequeuedAt time.Time) ([]byte, error) {
		firstContentBudgetMS := snapshot.firstContentBudgetMS
		if !snapshot.firstContentDeadline.IsZero() {
			remaining := snapshot.firstContentDeadline.Sub(dequeuedAt)
			if remaining <= 0 {
				return nil, errFirstContentDeadlineAtWriter
			}
			firstContentBudgetMS = remaining.Milliseconds()
			if firstContentBudgetMS < 1 {
				firstContentBudgetMS = 1
			}
		}
		data, err := json.Marshal(snapshot.wireMessage(firstContentBudgetMS))
		if err != nil {
			return nil, err
		}
		return data, nil
	}
}
