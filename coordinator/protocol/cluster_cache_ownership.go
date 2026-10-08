package protocol

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
)

// Cluster cache ownership contracts (private staging, default-off).
//
// Mirrors provider-swift/Sources/ProviderCore/KVCacheSSD/ClusterCacheOwnership.swift
// byte for byte: a cluster cache identity is scoped to the authorization
// boundary AND the exact model, prompt contract, build, layout/shard
// placement, precision and cache epoch. Absent or fuzzy fields are a safe
// miss; no cross-host raw-KV reuse exists in this contract. The shared
// Go/Swift vector pins the canonical encoding and namespace digest.

var ErrClusterCacheIdentity = errors.New("cluster cache identity has missing or fuzzy fields")
var ErrClusterCacheStaleWriter = errors.New("cluster cache writer is stale for this namespace and root")

func clusterCacheIsSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func clusterCacheBoundedLabel(value string, maximum int) bool {
	if len(value) == 0 || len(value) > maximum {
		return false
	}
	for _, b := range []byte(value) {
		if b < 33 || b > 126 {
			return false
		}
	}
	return true
}

// ClusterCacheIdentity is the exact cache identity for one cluster namespace.
type ClusterCacheIdentity struct {
	AuthorizationScopeSHA256 string
	ModelAggregateSHA256     string
	PromptContractID         string
	BuildSHA256              string
	LayoutSHA256             string
	ActivationDType          string
	CacheEpoch               string
}

func NewClusterCacheIdentity(authorizationScopeSHA256, modelAggregateSHA256, promptContractID,
	buildSHA256, layoutSHA256, activationDType, cacheEpoch string) (ClusterCacheIdentity, error) {
	identity := ClusterCacheIdentity{
		AuthorizationScopeSHA256: authorizationScopeSHA256,
		ModelAggregateSHA256:     modelAggregateSHA256,
		PromptContractID:         promptContractID,
		BuildSHA256:              buildSHA256,
		LayoutSHA256:             layoutSHA256,
		ActivationDType:          activationDType,
		CacheEpoch:               cacheEpoch,
	}
	if !clusterCacheIsSHA256(authorizationScopeSHA256) ||
		!clusterCacheIsSHA256(modelAggregateSHA256) ||
		!clusterCacheIsSHA256(buildSHA256) ||
		!clusterCacheIsSHA256(layoutSHA256) ||
		!clusterCacheBoundedLabel(promptContractID, 128) ||
		!clusterCacheBoundedLabel(cacheEpoch, 64) ||
		(activationDType != "float16" && activationDType != "bfloat16" && activationDType != "float32") {
		return ClusterCacheIdentity{}, ErrClusterCacheIdentity
	}
	return identity, nil
}

// ClusterCacheIdentityCanonical is the fixed-width canonical encoding; no
// JSON, optional fields or ambiguous joins. Mirrors canonicalBytes (Swift).
func (c ClusterCacheIdentity) ClusterCacheIdentityCanonical() []byte {
	result := []byte("darkbloom/cluster-cache-identity/v1\x00")
	for _, value := range []string{c.AuthorizationScopeSHA256, c.ModelAggregateSHA256, c.BuildSHA256, c.LayoutSHA256} {
		result = append(result, value...)
	}
	for _, value := range []string{c.PromptContractID, c.ActivationDType, c.CacheEpoch} {
		result = binary.BigEndian.AppendUint32(result, uint32(len(value)))
		result = append(result, value...)
	}
	return result
}

// NamespaceSHA256 is the single digest every writer/fence decision uses.
func (c ClusterCacheIdentity) NamespaceSHA256() string {
	sum := sha256.Sum256(c.ClusterCacheIdentityCanonical())
	return hex.EncodeToString(sum[:])
}

// ClusterCacheWriterLease is the authoritative-writer fence for one cache
// namespace on one physical storage root.
type ClusterCacheWriterLease struct {
	NamespaceSHA256 string
	PhysicalRootKey string
	OwnerProcessID  int32
	OwnerRank       int
	LeaseEpoch      uint64
}

func NewClusterCacheWriterLease(namespaceSHA256, physicalRootKey string,
	ownerProcessID int32, ownerRank int, leaseEpoch uint64) (ClusterCacheWriterLease, error) {
	lease := ClusterCacheWriterLease{
		NamespaceSHA256: namespaceSHA256, PhysicalRootKey: physicalRootKey,
		OwnerProcessID: ownerProcessID, OwnerRank: ownerRank, LeaseEpoch: leaseEpoch,
	}
	if !clusterCacheIsSHA256(namespaceSHA256) ||
		!clusterCacheBoundedLabel(physicalRootKey, 4096) ||
		len(physicalRootKey) == 0 || physicalRootKey[0] != '/' ||
		ownerProcessID <= 0 || ownerRank < 0 || ownerRank > 1 || leaseEpoch == 0 {
		return ClusterCacheWriterLease{}, ErrClusterCacheIdentity
	}
	return lease, nil
}

// AdmitsWriter is the ONLY write admission rule: anything that is not the
// exact recorded owner at the current epoch is a stale writer.
func (l ClusterCacheWriterLease) AdmitsWriter(processID int32, rank int, epoch uint64) error {
	if processID != l.OwnerProcessID || rank != l.OwnerRank || epoch != l.LeaseEpoch {
		return fmt.Errorf("%w", ErrClusterCacheStaleWriter)
	}
	return nil
}

// Superseded returns the replacement lease; reconnects of the previous owner
// never regain an old namespace.
func (l ClusterCacheWriterLease) Superseded(processID int32, rank int, epoch uint64) (ClusterCacheWriterLease, error) {
	if epoch <= l.LeaseEpoch || (processID == l.OwnerProcessID && rank == l.OwnerRank) {
		return ClusterCacheWriterLease{}, fmt.Errorf("%w", ErrClusterCacheStaleWriter)
	}
	return NewClusterCacheWriterLease(l.NamespaceSHA256, l.PhysicalRootKey, processID, rank, epoch)
}
