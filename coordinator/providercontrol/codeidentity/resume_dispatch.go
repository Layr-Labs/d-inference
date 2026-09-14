package codeidentity

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// sendCodeIdentityResumeChallenge performs a one-time private-key possession
// check over the live WebSocket. Cached SE+token+K equality only authorizes
// sending this challenge; it never grants capabilities by itself.
func (s *Manager) sendCodeIdentityResumeChallenge(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	nodeKeyB64, seKey, token string,
) bool {
	if s.deps.BeforeResumeIdentityCheck != nil {
		s.deps.BeforeResumeIdentityCheck()
	}
	provider.Mu().Lock()
	identityCurrent := provider.PublicKey == nodeKeyB64 &&
		provider.APNsDeviceToken == token
	provider.Mu().Unlock()
	if !identityCurrent {
		return false
	}
	rawKey, err := base64.StdEncoding.DecodeString(nodeKeyB64)
	if err != nil || len(rawKey) != 32 {
		return false
	}
	var nodeKey [32]byte
	copy(nodeKey[:], rawKey)
	session, err := e2e.GenerateSessionKeys()
	if err != nil {
		return false
	}
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return false
	}
	tokenHash := sha256.Sum256([]byte(token))
	nonce := base64.StdEncoding.EncodeToString(nonceBytes) + "." +
		base64.RawURLEncoding.EncodeToString(tokenHash[:])
	encrypted, err := e2e.Encrypt([]byte(nonce), nodeKey, session)
	if err != nil {
		return false
	}
	message := protocol.CodeAttestationResumeChallenge{
		Type: protocol.TypeCodeAttestationResumeChallenge,
		CodeChallenge: protocol.EncryptedPayload{
			EphemeralPublicKey: encrypted.EphemeralPublicKey,
			Ciphertext:         encrypted.Ciphertext,
		},
	}
	data, err := json.Marshal(message)
	if err != nil {
		return false
	}
	resumeDone := s.state.recordResumeChallenge(
		nonce, providerID, nodeKeyB64, seKey, token)
	if sender := s.deps.ResumeSender(); sender != nil {
		if err := sender(providerID, message); err != nil {
			s.state.consumeResumeChallenge(
				nonce, providerID, nodeKeyB64, seKey, token)
			return false
		}
		s.armCodeIdentityResumeFallback(
			ctx, providerID, provider, nonce, nodeKeyB64, seKey, token, resumeDone)
		return true
	}
	sendCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := provider.WriteText(sendCtx, data); err != nil {
		s.state.consumeResumeChallenge(
			nonce, providerID, nodeKeyB64, seKey, token)
		return false
	}
	s.armCodeIdentityResumeFallback(
		ctx, providerID, provider, nonce, nodeKeyB64, seKey, token, resumeDone)
	return true
}

func (s *Manager) armCodeIdentityResumeFallback(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
	nonce, nodeKey, seKey, token string,
	done <-chan struct{},
) {
	expiresAt, ok := s.state.resumeChallengeExpiry(
		nonce, providerID, nodeKey, seKey, token,
	)
	if !ok {
		return
	}
	saferun.Go(s.deps.Logger, "codeAttestResumeFallback", func() {
		delay := time.Until(expiresAt)
		if delay < 0 {
			delay = 0
		}
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return
		case <-done:
			return
		case <-timer.C:
		}
		if !s.state.expireResumeChallenge(
			nonce, providerID, nodeKey, seKey, token,
		) {
			return // response, disconnect cleanup, or another timer won
		}
		if s.deps.BeforeResumeFallbackAPNs != nil {
			s.deps.BeforeResumeFallbackAPNs()
		}
		if ctx.Err() != nil {
			return // connection canceled after timer won; do not spend APNs budget
		}
		s.deps.Metric("resume_timeout")
		s.codeAttestLoopWithResume(ctx, providerID, provider, false)
	})
}
