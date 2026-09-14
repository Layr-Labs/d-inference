package store

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

const MaxSandboxPayloadRedactionBatch = 32

// The commitment mirrors the exact fields compared by SameRequest. It remains
// internal and immutable after payload expiry; it is not encryption or a claim
// that low-entropy command values cannot be guessed from a database copy.
func sandboxCommandRequestDigest(command *SandboxCommand) string {
	request := struct {
		AccountID        string            `json:"account_id"`
		SandboxID        string            `json:"sandbox_id"`
		IdempotencyKey   string            `json:"idempotency_key"`
		TimeoutSeconds   uint32            `json:"timeout_seconds"`
		WorkingDirectory string            `json:"working_directory"`
		Arguments        []string          `json:"arguments"`
		Environment      map[string]string `json:"environment"`
	}{command.AccountID, command.SandboxID, command.IdempotencyKey, command.TimeoutSeconds,
		command.WorkingDirectory, command.Arguments, command.Environment}
	encoded, _ := json.Marshal(request) // The closed primitive shape cannot fail.
	digest := sha256.Sum256(append([]byte("darkbloom-sandbox-command-request-v1\x00"), encoded...))
	return hex.EncodeToString(digest[:])
}

func sameSandboxCommandRequest(command, candidate *SandboxCommand) bool {
	if command == nil || candidate == nil {
		return false
	}
	digest := command.RequestDigest
	if !command.PayloadExpired {
		current := sandboxCommandRequestDigest(command)
		if digest != "" && digest != current {
			return false
		}
		digest = current
	} else if digest == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(digest), []byte(sandboxCommandRequestDigest(candidate))) == 1
}

func redactSandboxCommandPayload(command *SandboxCommand, at time.Time) error {
	if command == nil || !command.Terminal() || command.CancellationPending || command.PayloadExpired {
		return ErrSandboxConflict
	}
	digest := sandboxCommandRequestDigest(command)
	if command.RequestDigest != "" && command.RequestDigest != digest {
		return errors.New("sandbox command request commitment mismatch")
	}
	command.RequestDigest = digest
	command.Arguments = []string{}
	command.Environment = nil
	command.WorkingDirectory = ""
	command.StandardOutput = ""
	command.StandardError = ""
	command.PayloadExpired = true
	command.PayloadExpiredAt = &at
	return nil
}

func sandboxPayloadRedactionLimit(limit int) int {
	if limit <= 0 || limit > MaxSandboxPayloadRedactionBatch {
		return MaxSandboxPayloadRedactionBatch
	}
	return limit
}
