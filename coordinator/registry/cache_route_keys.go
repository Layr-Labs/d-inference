package registry

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"

	cacheactivation "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func decodeCacheMasterKey(raw string) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("key is empty")
	}
	decoders := []func(string) ([]byte, error){
		base64.RawURLEncoding.DecodeString,
		base64.URLEncoding.DecodeString,
		base64.RawStdEncoding.DecodeString,
		base64.StdEncoding.DecodeString,
		hex.DecodeString,
	}
	for _, decode := range decoders {
		if key, err := decode(raw); err == nil && len(key) == 32 {
			return key, nil
		}
	}
	return nil, errors.New("key must encode exactly 32 bytes as base64url, base64, or hex")
}

// Derivation labels. Every persisted holder and demand key is a function of
// the master key and of these versions, so all of them feed the persistence
// fingerprint below: bumping any one resets the durable copy on the next boot
// instead of restoring keys no request can derive.
const (
	cacheRouteKeyLabel         = "darkbloom/cache-routing/route/v3"
	cacheScopeKeyLabel         = "darkbloom/cache-routing/scope/v3"
	cacheActivationKeyLabel    = "darkbloom/cache-routing/activation/v1"
	cacheScopeSerialization    = "scope-v3"
	cacheBoundarySerialization = cacheplan.BoundarySerialization
	// cachePersistenceGeneration names the persisted row schema and the key
	// serialization as a whole; bump it with any change to either that the
	// labels above do not already capture.
	cachePersistenceGeneration = "persist/v1"
)

func deriveCacheKeys(master []byte) cacheRouteKeys {
	return cacheRouteKeys{
		route:      cacheactivation.HMACBytes(master, []byte(cacheRouteKeyLabel)),
		scope:      cacheactivation.HMACBytes(master, []byte(cacheScopeKeyLabel)),
		activation: cacheactivation.HMACBytes(master, []byte(cacheActivationKeyLabel)),
		// A non-secret marker of this key generation (cachepersist.Restore):
		// the master key plus every derivation version and the block
		// contract the keys are serialized under.
		persistFingerprint: hex.EncodeToString(cacheactivation.HMACBytes(master,
			[]byte("darkbloom/cache-routing/persistence-fingerprint/v1"),
			[]byte(cacheRouteKeyLabel), []byte(cacheScopeKeyLabel), []byte(cacheActivationKeyLabel),
			[]byte(cacheScopeSerialization), []byte(cacheBoundarySerialization),
			[]byte(promptcontract.BlockHashVersion), []byte(strconv.FormatUint(uint64(promptcontract.BlockSize), 10)),
			[]byte(cachePersistenceGeneration)))[:24],
	}
}

func opaqueHMAC(key []byte, parts ...string) string {
	return cacheactivation.OpaqueHMAC(key, parts...)
}

// CachePlanInput is the final provider-bound text request plus immutable
// catalog identity. Callers supply a ready prompt-contract ID from the
// verified artifact provisioner.
type CachePlanInput struct {
	Account              string
	Model                string
	PromptContractID     string
	ModelAggregateSHA256 string
	Body                 []byte
	HasMedia             bool
}

type CachePlanResult struct {
	// PromptWork is valid tokenizer accounting even when there are no reusable boundaries.
	PromptWork    *protocol.PromptWork
	Plan          CachePlan
	Outcome       cacheactivation.CachePlanOutcome
	PlanLatency   time.Duration
	SidecarCalled bool
}

// PlanCacheRoute asks the local sidecar for exact block boundaries. Every
// failure is fail-cold: inference continues with an empty plan.
func (r *Registry) PlanCacheRoute(
	ctx context.Context,
	client *promptcontract.Client,
	input CachePlanInput,
) CachePlan {
	return r.PlanCacheRouteWithResult(ctx, client, input).Plan
}

// PlanCacheRouteWithResult is the observable form of PlanCacheRoute. It keeps
// the same fail-cold contract. Outcome, PlanLatency, and SidecarCalled are the
// only fields safe for metrics; Plan retains the existing private route scope
// and hashes and must remain request-local.
func (r *Registry) PlanCacheRouteWithResult(
	ctx context.Context,
	client *promptcontract.Client,
	input CachePlanInput,
) CachePlanResult {
	if r == nil || cachePlanInputIneligible(client != nil, input) {
		return CachePlanResult{Outcome: cacheactivation.CachePlanIneligible}
	}

	state := r.snapshotCachePlanAuthority(input.Model, true)
	if outcome := cachePlanAuthorityRejection(state, input); outcome != "" {
		return CachePlanResult{Outcome: outcome}
	}
	tracker, keys, activation := state.tracker, state.keys, state.activation
	aggregateHash := strings.ToLower(strings.TrimSpace(state.catalog.WeightHash))

	scope := providerCacheScope(
		keys.scope,
		input.Account,
		input.Model,
		aggregateHash,
		input.PromptContractID,
	)
	if scope == "" {
		return CachePlanResult{Outcome: cacheactivation.CachePlanIneligible}
	}
	// The sampling cohort is stable for identical account + resolved model +
	// provider-bound body so a sampled miss can later donate and hit. Only this
	// keyed digest reaches the gate; raw identity/prompt bytes are never stored,
	// logged, persisted, tagged, or returned.
	cohort := cacheactivation.Cohort(keys.activation, input.Account, input.Model, input.Body)
	// The diagnostic preflight is not authorization. Revalidate current policy
	// at the one activation commit; no callback, HMAC or IO runs under this lock.
	// Gate.Allow holds only its own scalar counter/token mutex and never enters r.
	r.mu.RLock()
	currentAuthority := r.cachePlanAuthorityLocked(input.Model, false)
	if r.cacheRouting != tracker || !tracker.generation.Active() {
		outcome := cacheactivation.CachePlanIneligible
		if currentAuthority.mode != CacheRoutingOn {
			outcome = cacheactivation.CachePlanOff
		}
		r.mu.RUnlock()
		return CachePlanResult{Outcome: outcome}
	}
	if outcome := cachePlanAuthorityRejection(currentAuthority, input); outcome != "" {
		r.mu.RUnlock()
		return CachePlanResult{Outcome: outcome}
	}
	decision := activation.Allow(cohort, time.Now())
	r.mu.RUnlock()
	switch decision {
	case cacheactivation.SampledOut:
		return CachePlanResult{Outcome: cacheactivation.CachePlanSampledOut}
	case cacheactivation.Throttled:
		return CachePlanResult{Outcome: cacheactivation.CachePlanThrottled}
	}
	started := time.Now()
	sidecarPlan, err := client.Plan(ctx, promptcontract.PlanInput{
		PromptContractID: input.PromptContractID,
		ScopeID:          scope,
		Endpoint:         promptcontract.EndpointChatCompletions,
		Body:             input.Body,
	})
	latency := time.Since(started)
	r.mu.RLock()
	currentMode := r.cacheRoutingMode
	current := r.cacheRouting == tracker && currentMode == CacheRoutingOn
	r.mu.RUnlock()
	if !current {
		outcome := cacheactivation.CachePlanIneligible
		if currentMode == CacheRoutingOff {
			outcome = cacheactivation.CachePlanOff
		}
		return CachePlanResult{Outcome: outcome, PlanLatency: latency, SidecarCalled: true}
	}
	if err != nil {
		outcome := cacheactivation.CachePlanSidecarError
		if errors.Is(err, promptcontract.ErrDynamicContract) {
			outcome = cacheactivation.CachePlanColdOnly
		} else if errors.Is(err, promptcontract.ErrInvalidPlan) ||
			errors.Is(err, promptcontract.ErrPlanTooLarge) {
			outcome = cacheactivation.CachePlanInvalid
		}
		activation.RecordPlan(outcome)
		return CachePlanResult{
			Outcome: outcome, PlanLatency: latency, SidecarCalled: true,
		}
	}
	if !sidecarPlan.Participating {
		activation.RecordPlan(cacheactivation.CachePlanInvalid)
		return CachePlanResult{
			Outcome: cacheactivation.CachePlanInvalid, PlanLatency: latency, SidecarCalled: true,
		}
	}
	work := &protocol.PromptWork{Version: protocol.PromptWorkVersion, Source: protocol.PromptWorkExact,
		PromptTokens: int(sidecarPlan.PromptTokenCount), UpperBoundTokens: int(sidecarPlan.PromptTokenCount),
		PromptContractID: input.PromptContractID, ModelArtifactHash: aggregateHash}
	if !work.IsQualifiedFor(aggregateHash, input.PromptContractID) {
		work = nil
	}
	if len(sidecarPlan.BlockBoundaries) == 0 {
		activation.RecordPlan(cacheactivation.CachePlanNoBoundaries)
		return CachePlanResult{
			PromptWork: work, Outcome: cacheactivation.CachePlanNoBoundaries, PlanLatency: latency, SidecarCalled: true,
		}
	}
	plan, accepted := cacheplan.PlanFromSidecar(tracker.generation, cacheplan.Identity{
		ModelAggregateHash: aggregateHash, PromptContractID: input.PromptContractID, CacheScope: scope,
	}, sidecarPlan)
	if !accepted {
		activation.RecordPlan(cacheactivation.CachePlanInvalid)
		return CachePlanResult{
			Outcome: cacheactivation.CachePlanInvalid, PlanLatency: latency, SidecarCalled: true,
		}
	}
	activation.RecordPlanned(tracker.observeCacheDemand(&plan, keys.route, time.Now()))
	return CachePlanResult{Plan: plan, PromptWork: work, Outcome: cacheactivation.CachePlanPlanned, PlanLatency: latency, SidecarCalled: true}
}

// providerCacheScope is the only provider-visible routing value. It binds the
// account to one concrete model build and prompt contract without exposing any
// of those values.
func providerCacheScope(
	scopeKey []byte,
	account, model, aggregateHash, promptContractID string,
) string {
	if len(scopeKey) == 0 || account == "" || model == "" ||
		!validLowerHex256(strings.ToLower(aggregateHash)) ||
		!validLowerHex256(promptContractID) {
		return ""
	}
	return opaqueHMAC(
		scopeKey,
		cacheScopeSerialization,
		account,
		model,
		strings.ToLower(aggregateHash),
		promptContractID,
		promptcontract.BlockHashVersion,
		strconv.FormatUint(uint64(promptcontract.BlockSize), 10),
	)
}

// cacheBoundaryKey identifies reusable content, independent of which provider
// holds it. Epochs are validated holder metadata: putting one in this key would
// split identical prefixes into separate buckets and bypass the holder bound.
func cacheBoundaryKey(
	routeKey []byte,
	plan CachePlan,
	anchor protocol.PrefixCacheAnchor,
) string {
	return plan.BoundaryKey(routeKey, anchor)
}
