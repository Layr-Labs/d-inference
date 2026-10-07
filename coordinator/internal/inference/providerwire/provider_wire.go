// Package providerwire prepares immutable request frames for dequeue-time encoding.
package providerwire

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

var ErrDeadlineExpired = errors.New(DeadlineExpiredMessage)

type providerInferenceFrameSnapshot struct {
	requestID            string
	serviceReservationID string
	ephemeralPublicKey   string
	ciphertext           string
	firstContentBudgetMS int64
	firstContentDeadline time.Time
	cacheAttempt         registry.CacheAttemptSnapshot
	promptWork           *protocol.PromptWork
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
	if pr.PromptWork != nil {
		work := *pr.PromptWork
		snapshot.promptWork = &work
	}
	snapshot.firstContentBudgetMS = pr.FirstContentBudgetMS
	snapshot.serviceReservationID = pr.ServiceReservationID()
	snapshot.firstContentDeadline = pr.FirstContentDeadline
	snapshot.cacheAttempt = pr.CacheAttemptSnapshot()
	return snapshot
}

func (snapshot providerInferenceFrameSnapshot) wireMessage(
	firstContentBudgetMS int64,
) protocol.InferenceRequestMessage {
	message := protocol.InferenceRequestMessage{
		Type:                       protocol.TypeInferenceRequest,
		RequestID:                  snapshot.requestID,
		ServiceReservationID:       snapshot.serviceReservationID,
		PromptWork:                 snapshot.promptWork,
		ToolSchemaMetadataProtocol: 1,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: snapshot.ephemeralPublicKey,
			Ciphertext:         snapshot.ciphertext,
		},
	}
	if firstContentBudgetMS > 0 {
		message.FirstContentBudgetMS = firstContentBudgetMS
	}
	snapshot.cacheAttempt.ApplyTo(&message)
	return message
}

// FrameBuilder defers the deadline-sensitive outer frame until
// the request reaches the head of the provider's data lane. Encryption and
// cache preparation are already complete; only the remaining budget and JSON
// envelope are produced here.
func FrameBuilder(
	requestID, ephemeralPublicKey, ciphertext string,
	pr *registry.PendingRequest,
) registry.TextFrameBuilder {
	snapshot := snapshotProviderInferenceFrame(
		requestID, ephemeralPublicKey, ciphertext, pr)
	var profile *registry.AttemptProfile
	if pr != nil {
		profile = pr.Profile
	}
	return func(dequeuedAt time.Time) ([]byte, error) {
		firstContentBudgetMS := snapshot.firstContentBudgetMS
		if !snapshot.firstContentDeadline.IsZero() {
			remaining := snapshot.firstContentDeadline.Sub(dequeuedAt)
			if remaining <= 0 {
				return nil, ErrDeadlineExpired
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
		profile.RecordDispatchBudget(firstContentBudgetMS)
		return data, nil
	}
}
