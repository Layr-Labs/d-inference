package registry

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"

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

func deriveCacheKeys(master []byte) cacheRouteKeys {
	return cacheRouteKeys{
		route:      hmacBytes(master, []byte("darkbloom/cache-routing/route/v3")),
		scope:      hmacBytes(master, []byte("darkbloom/cache-routing/scope/v3")),
		activation: hmacBytes(master, []byte("darkbloom/cache-routing/activation/v1")),
	}
}

func hmacBytes(key []byte, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, key)
	var n [4]byte
	for _, part := range parts {
		binary.BigEndian.PutUint32(n[:], uint32(len(part)))
		_, _ = m.Write(n[:])
		_, _ = m.Write(part)
	}
	return m.Sum(nil)
}

func opaqueHMAC(key []byte, parts ...string) string {
	values := make([][]byte, 0, len(parts))
	for _, part := range parts {
		values = append(values, []byte(part))
	}
	return base64.RawURLEncoding.EncodeToString(hmacBytes(key, values...))
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

// CachePlanOutcome is deliberately low-cardinality and privacy-safe so it can
// be used directly in operational metrics.
type CachePlanOutcome string

const (
	CachePlanOff          CachePlanOutcome = "off"
	CachePlanIneligible   CachePlanOutcome = "ineligible"
	CachePlanSampledOut   CachePlanOutcome = "sampled_out"
	CachePlanThrottled    CachePlanOutcome = "throttled"
	CachePlanColdOnly     CachePlanOutcome = "cold_only"
	CachePlanSidecarError CachePlanOutcome = "sidecar_error"
	CachePlanNoBoundaries CachePlanOutcome = "no_boundaries"
	CachePlanInvalid      CachePlanOutcome = "invalid_plan"
	CachePlanPlanned      CachePlanOutcome = "planned"
)

type CachePlanResult struct {
	Plan          CachePlan
	Outcome       CachePlanOutcome
	PlanLatency   time.Duration
	SidecarCalled bool
}

// PlanCacheRoute derives the authenticated scope, then asks the local sidecar
// for SSD block boundaries. Sidecar failures keep only the scope so an
// advertised exact RAM tier can proceed while SSD routing remains cold.
func (r *Registry) PlanCacheRoute(
	ctx context.Context,
	client *promptcontract.Client,
	input CachePlanInput,
) CachePlan {
	return r.PlanCacheRouteWithResult(ctx, client, input).Plan
}

// PlanCacheScope derives only the authenticated, build-bound tenant scope.
// This path has no prompt-sidecar, block-boundary, or receipt dependency and
// is sufficient for an exact process-local RAM cache. Empty means fail-cold.
func (r *Registry) PlanCacheScope(input CachePlanInput) CachePlan {
	plan, _ := r.planCacheScope(input)
	if !plan.scopePresent() {
		return CachePlan{}
	}
	if r.exactCacheScopeActivation(input) != cacheActivationAdmitted {
		return CachePlan{}
	}
	return plan
}

func (r *Registry) exactCacheScopeActivation(
	input CachePlanInput,
) cacheActivationDecision {
	r.mu.RLock()
	mode := r.cacheRoutingMode
	activationKey := append([]byte(nil), r.cacheRouteKeys.activation...)
	activation := r.cacheActivation
	r.mu.RUnlock()
	if mode != CacheRoutingOn {
		return cacheActivationSampledOut
	}
	cohort := cacheActivationCohort(
		activationKey, input.Account, input.Model, input.Body)
	return activation.allowScope(cohort)
}

func (r *Registry) planCacheScope(
	input CachePlanInput,
) (CachePlan, CachePlanOutcome) {
	if r == nil || input.HasMedia ||
		input.Account == "" || input.Model == "" ||
		!validLowerHex256(input.PromptContractID) ||
		!validLowerHex256(input.ModelAggregateSHA256) {
		return CachePlan{}, CachePlanIneligible
	}

	r.mu.RLock()
	mode := r.cacheRoutingMode
	scopeKey := append([]byte(nil), r.cacheRouteKeys.scope...)
	catalog, ok := r.modelCatalog[input.Model]
	r.mu.RUnlock()
	if mode != CacheRoutingOn {
		return CachePlan{}, CachePlanOff
	}
	aggregateHash := strings.ToLower(strings.TrimSpace(catalog.WeightHash))
	if !ok || !validLowerHex256(aggregateHash) ||
		aggregateHash != input.ModelAggregateSHA256 {
		return CachePlan{}, CachePlanIneligible
	}
	scope := providerCacheScope(
		scopeKey,
		input.Account,
		input.Model,
		aggregateHash,
		input.PromptContractID,
	)
	if scope == "" {
		return CachePlan{}, CachePlanIneligible
	}
	return CachePlan{
		ModelAggregateHash: aggregateHash,
		PromptContractID:   input.PromptContractID,
		CacheScope:         scope,
	}, CachePlanPlanned
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
	scopePlan, scopeOutcome := r.planCacheScope(input)
	if !scopePlan.scopePresent() {
		return CachePlanResult{Outcome: scopeOutcome}
	}
	if len(input.Body) == 0 {
		return CachePlanResult{Outcome: CachePlanIneligible}
	}
	if client == nil {
		if r.exactCacheScopeActivation(input) != cacheActivationAdmitted {
			return CachePlanResult{Outcome: CachePlanSampledOut}
		}
		return CachePlanResult{Plan: scopePlan, Outcome: CachePlanIneligible}
	}

	r.mu.RLock()
	keys := cacheRouteKeys{
		route:      append([]byte(nil), r.cacheRouteKeys.route...),
		activation: append([]byte(nil), r.cacheRouteKeys.activation...),
	}
	activation := r.cacheActivation
	r.mu.RUnlock()
	if len(keys.route) == 0 || len(keys.activation) == 0 || activation == nil {
		return CachePlanResult{Plan: scopePlan, Outcome: CachePlanIneligible}
	}
	// The sampling cohort is stable for identical account + resolved model +
	// provider-bound body so a sampled miss can later donate and hit. Only this
	// keyed digest reaches the gate; raw identity/prompt bytes are never stored,
	// logged, persisted, tagged, or returned.
	cohort := cacheActivationCohort(keys.activation, input.Account, input.Model, input.Body)
	switch activation.allow(cohort, time.Now()) {
	case cacheActivationSampledOut:
		return CachePlanResult{Outcome: CachePlanSampledOut}
	case cacheActivationThrottled:
		return CachePlanResult{Plan: scopePlan, Outcome: CachePlanThrottled}
	}
	started := time.Now()
	sidecarPlan, err := client.Plan(ctx, promptcontract.PlanInput{
		PromptContractID: input.PromptContractID,
		ScopeID:          scopePlan.CacheScope,
		Endpoint:         promptcontract.EndpointChatCompletions,
		Body:             input.Body,
	})
	latency := time.Since(started)
	if err != nil {
		outcome := CachePlanSidecarError
		if errors.Is(err, promptcontract.ErrDynamicContract) {
			outcome = CachePlanColdOnly
		} else if errors.Is(err, promptcontract.ErrInvalidPlan) ||
			errors.Is(err, promptcontract.ErrPlanTooLarge) {
			outcome = CachePlanInvalid
		}
		activation.recordPlan(outcome)
		return CachePlanResult{
			Plan: scopePlan, Outcome: outcome, PlanLatency: latency, SidecarCalled: true,
		}
	}
	if !sidecarPlan.Participating {
		activation.recordPlan(CachePlanInvalid)
		return CachePlanResult{
			Plan: scopePlan, Outcome: CachePlanInvalid, PlanLatency: latency, SidecarCalled: true,
		}
	}
	if len(sidecarPlan.BlockBoundaries) == 0 {
		activation.recordPlan(CachePlanNoBoundaries)
		return CachePlanResult{
			Plan: scopePlan, Outcome: CachePlanNoBoundaries, PlanLatency: latency, SidecarCalled: true,
		}
	}
	boundaries := make([]protocol.PrefixCacheAnchor, 0, len(sidecarPlan.BlockBoundaries))
	for _, boundary := range sidecarPlan.BlockBoundaries {
		anchor := protocol.PrefixCacheAnchor{
			TokenCount: int(boundary.TokenCount),
			ChainHash:  boundary.ChainHash,
		}
		if !validV2Anchor(anchor, promptcontract.BlockSize) {
			activation.recordPlan(CachePlanInvalid)
			return CachePlanResult{
				Plan: scopePlan, Outcome: CachePlanInvalid, PlanLatency: latency, SidecarCalled: true,
			}
		}
		boundaries = append(boundaries, anchor)
	}
	activation.recordPlan(CachePlanPlanned)
	return CachePlanResult{
		Plan: CachePlan{
			ModelAggregateHash: scopePlan.ModelAggregateHash,
			PromptContractID:   scopePlan.PromptContractID,
			CacheScope:         scopePlan.CacheScope,
			PromptTokenCount:   int(sidecarPlan.PromptTokenCount),
			Boundaries:         boundaries,
		},
		Outcome: CachePlanPlanned, PlanLatency: latency, SidecarCalled: true,
	}
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
		"scope-v3",
		account,
		model,
		strings.ToLower(aggregateHash),
		promptContractID,
		promptcontract.BlockHashVersion,
		strconv.FormatUint(uint64(promptcontract.BlockSize), 10),
	)
}

func cacheBoundaryKey(
	routeKey []byte,
	plan CachePlan,
	cacheEpoch string,
	anchor protocol.PrefixCacheAnchor,
) string {
	if len(routeKey) == 0 || !plan.present() || !validCacheEpoch(cacheEpoch) ||
		!validV2Anchor(anchor, promptcontract.BlockSize) {
		return ""
	}
	return opaqueHMAC(
		routeKey,
		"prefix-v3",
		plan.CacheScope,
		plan.ModelAggregateHash,
		plan.PromptContractID,
		cacheEpoch,
		strconv.Itoa(anchor.TokenCount),
		anchor.ChainHash,
	)
}
