package inference

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type queuedHandoffResult struct {
	Outcome      attempt.Outcome
	Failure      *retry.AttemptFailure
	BodyBytes    int
	BodyOverflow bool
	RouteOutcome *store.InferenceRouteOutcome
}

// handoffQueuedProvider uses the reservation already assigned by the queue.
func (s *Owner) handoffQueuedProvider(in providerdispatch.Input, provider *registry.Provider, pr *registry.PendingRequest, accounting *providerwire.Accounting) queuedHandoffResult {
	result := queuedHandoffResult{Outcome: attempt.Proceed}
	requestID := pr.RequestID

	// Log missing payout destination but don't skip: earnings are credited to
	// the internal ledger and can be withdrawn after Stripe Connect onboarding.
	// A queued request settles free on the caller's own machine, including a
	// prefer-owner selection. A custom-price top-up must not reject that route.
	queuedSettlesFree := in.Scope.SelfRouteOnly
	if !queuedSettlesFree && in.Scope.PreferOwner {
		provider.Mu().Lock()
		queuedSettlesFree = in.Scope.OwnerAccountID != "" && provider.AccountID == in.Scope.OwnerAccountID
		provider.Mu().Unlock()
	}

	if s.billing != nil && !queuedSettlesFree && !providerdispatch.ProviderHasPayoutDestination(provider) {
		s.logger.Warn("queued provider missing payout destination, crediting to internal ledger",
			"request_id", requestID,
			"provider_id", provider.ID,
		)
	}

	// Custom pricing may require an additional reservation. Free self-routes
	// settle at zero cost and skip the top-up.
	if s.billing != nil && !queuedSettlesFree {
		if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			in.Exclusions.Exclude(provider.ID)
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.logger.Warn("queued provider pricing exceeds balance, skipping",
					"request_id", requestID,
					"provider_id", provider.ID,
					"error", err,
				)
				failure := retry.CoordinatorFailure("insufficient funds for provider price", http.StatusPaymentRequired)
				result.Failure = &failure
				result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "insufficient_funds", result.Failure.Message)
			} else {
				s.logger.Error("queued provider reservation failed (DB error)",
					"request_id", requestID,
					"provider_id", provider.ID,
					"error", err,
				)
				failure := retry.CoordinatorFailure("service temporarily unavailable \u2014 please retry", http.StatusServiceUnavailable)
				result.Failure = &failure
				result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "provider_error", result.Failure.Message)
			}
			result.Outcome = attempt.Retry
			return result
		}
	}
	// Perform E2E encryption and send the request.
	if provider.PublicKey == "" {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundProviderExtra(pr)
		in.Exclusions.Exclude(provider.ID)
		failure := retry.CoordinatorFailure("no provider with E2E encryption", 0)
		result.Failure = &failure
		result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "encryption_missing", result.Failure.Message)
		result.Outcome = attempt.Retry
		return result
	}
	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundProviderExtra(pr)
		in.Exclusions.Exclude(provider.ID)
		failure := retry.CoordinatorFailure("provider public key invalid", 0)
		result.Failure = &failure
		result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "provider_error", result.Failure.Message)
		result.Outcome = attempt.Retry
		return result
	}
	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundProviderExtra(pr)
		failure := retry.CoordinatorFailure("failed to generate session keys", 0)
		result.Failure = &failure
		result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "provider_error", result.Failure.Message)
		result.Outcome = attempt.Retry
		return result
	}
	if err := s.registry.PrepareCacheAttempt(pr, provider); err != nil {
		s.registry.ForgetCacheAttempt(pr)
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundProviderExtra(pr)
		failure := retry.CoordinatorFailure("failed to prepare cache-safe request", http.StatusInternalServerError)
		result.Failure = &failure
		result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "provider_error", result.Failure.Message)
		result.Outcome = attempt.Retry
		return result
	}
	// Protocol-0 cache isolation. The queued path seals here, separately from
	// the ordinary provider dispatch path.
	sealedBody, err := providerwire.BodyForCacheAttempt(in.Body, pr.LegacyCacheBustKey)
	if err != nil {
		s.registry.ForgetCacheAttempt(pr)
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundProviderExtra(pr)
		if errors.Is(err, providerwire.ErrBodyTooLarge) {
			in.Exclusions.Exclude(provider.ID)
			failure := retry.CoordinatorFailure(err.Error(), http.StatusRequestEntityTooLarge)
			result.Failure = &failure
			result.BodyBytes = providerwire.OversizedBodyBytes(err)
			result.BodyOverflow = true
			result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", routeoutcome.ErrorClassClientError, result.Failure.Message)
			result.Outcome = attempt.Retry
			return result
		}
		failure := retry.CoordinatorFailure("failed to prepare provider request", http.StatusInternalServerError)
		result.Failure = &failure
		result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "provider_error", result.Failure.Message)
		result.Outcome = attempt.Retry
		return result
	}
	encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.ForgetCacheAttempt(pr)
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundProviderExtra(pr)
		failure := retry.CoordinatorFailure("failed to encrypt request", 0)
		result.Failure = &failure
		result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "encryption_missing", result.Failure.Message)
		result.Outcome = attempt.Retry
		return result
	}
	in.Timing.EncryptedAt = time.Now()
	pr.Profile.Mark(registry.StampEncrypted)
	pr.SessionPrivKey = &sessionKeys.PrivateKey
	// The queued reservation may have been increased by the top-up; do not
	// overwrite pr.ReservedMicroUSD. Bound the write by the absolute first-token
	// clock so a blocked writer cannot outlive the request's remaining budget.
	writeCtx, cancelWrite := firstcontent.FirstTokenWriteContext(in.Request.Context(), firstcontent.TimingReceivedAt(in.Timing), in.Deadline)
	pr.Profile.Mark(registry.StampWriteSubmitted)
	_, writeErr := accounting.WriteQueued(writeCtx, provider, pr,
		providerwire.FrameBuilder(requestID, encrypted.EphemeralPublicKey, encrypted.Ciphertext, pr))
	cancelWrite()
	if writeErr == nil {
		pr.Profile.Mark(registry.StampWriteDone)
	}
	if writeErr != nil {
		s.registry.ForgetCacheAttempt(pr)
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.refundProviderExtra(pr)
		in.Exclusions.Exclude(provider.ID)
		if errors.Is(writeErr, context.DeadlineExceeded) ||
			errors.Is(writeErr, providerwire.ErrDeadlineExpired) {
			pr.Profile.Mark(registry.StampCancelSent)
			s.sendProviderCancel(provider, requestID)
			failure := retry.CoordinatorFailure("timeout waiting for first response", http.StatusGatewayTimeout)
			result.Failure = &failure
			result.RouteOutcome = retry.ErrorRouteOutcome(pr, "timeout", "first_chunk_timeout", result.Failure.Message)
			result.Outcome = attempt.FailFast
			return result
		}
		if errors.Is(writeErr, registry.ErrProviderDraining) {
			failure := retry.CoordinatorFailure(protocol.ProviderDrainingForUpdate, http.StatusServiceUnavailable)
			result.Failure = &failure
			result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "draining", result.Failure.Message)
			result.Outcome = attempt.Retry
			return result
		}
		failure := retry.CoordinatorFailure("failed to send request to provider", 0)
		result.Failure = &failure
		result.RouteOutcome = retry.ErrorRouteOutcome(pr, "error", "provider_error", result.Failure.Message)
		result.Outcome = attempt.Retry
		return result
	}
	return result
}
