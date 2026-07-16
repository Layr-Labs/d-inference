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
		route: hmacBytes(master, []byte("darkbloom/cache-routing/route/v3")),
		scope: hmacBytes(master, []byte("darkbloom/cache-routing/scope/v3")),
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
	Account          string
	Model            string
	PromptContractID string
	Body             []byte
	HasMedia         bool
}

// PlanCacheRoute asks the local sidecar for exact block boundaries. Every
// failure is fail-cold: inference continues with an empty plan.
func (r *Registry) PlanCacheRoute(
	ctx context.Context,
	client *promptcontract.Client,
	input CachePlanInput,
) CachePlan {
	if r == nil || client == nil || input.HasMedia ||
		input.Account == "" || input.Model == "" ||
		!validLowerHex256(input.PromptContractID) || len(input.Body) == 0 {
		return CachePlan{}
	}

	r.mu.RLock()
	mode := r.cacheRoutingMode
	keys := cacheRouteKeys{
		route: append([]byte(nil), r.cacheRouteKeys.route...),
		scope: append([]byte(nil), r.cacheRouteKeys.scope...),
	}
	catalog, ok := r.modelCatalog[input.Model]
	r.mu.RUnlock()
	aggregateHash := strings.ToLower(strings.TrimSpace(catalog.WeightHash))
	if mode != CacheRoutingOn || !ok || len(keys.route) == 0 ||
		!validLowerHex256(aggregateHash) {
		return CachePlan{}
	}

	scope := providerCacheScope(
		keys.scope,
		input.Account,
		input.Model,
		aggregateHash,
		input.PromptContractID,
	)
	if scope == "" {
		return CachePlan{}
	}
	sidecarPlan := client.PlanFailCold(ctx, promptcontract.PlanInput{
		PromptContractID: input.PromptContractID,
		ScopeID:          scope,
		Endpoint:         promptcontract.EndpointChatCompletions,
		Body:             input.Body,
	})
	if !sidecarPlan.Participating || len(sidecarPlan.BlockBoundaries) == 0 {
		return CachePlan{}
	}
	boundaries := make([]protocol.PrefixCacheAnchor, 0, len(sidecarPlan.BlockBoundaries))
	for _, boundary := range sidecarPlan.BlockBoundaries {
		anchor := protocol.PrefixCacheAnchor{
			TokenCount: int(boundary.TokenCount),
			ChainHash:  boundary.ChainHash,
		}
		if !validV2Anchor(anchor, promptcontract.BlockSize) {
			return CachePlan{}
		}
		boundaries = append(boundaries, anchor)
	}
	return CachePlan{
		ModelAggregateHash: aggregateHash,
		PromptContractID:   input.PromptContractID,
		CacheScope:         scope,
		PromptTokenCount:   int(sidecarPlan.PromptTokenCount),
		Boundaries:         boundaries,
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
