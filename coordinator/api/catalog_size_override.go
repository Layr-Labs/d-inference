package api

import "github.com/eigeninference/d-inference/coordinator/store"

// catalogSizeGBOverrideKey is the RuntimeParameters key an operator sets to
// override the auto-computed CatalogEntry.SizeGB for a model registry row.
//
// Background: SyncModelCatalog normally derives SizeGB from
// ActiveVersion.TotalSizeBytes — the model's raw on-disk manifest size. That
// is the correct "weight the provider must load" for an ordinary resident
// model, and every coordinator memory gate downstream (modelFitsHardware's
// SizeGB fallback, registry.reportedFreeForLoadAdmits,
// registry.freeMemoryAdmits, registry.coldTokenBudgetEstimate) is written
// against that assumption.
//
// MoE expert-SSD-streaming models (DeepSeek-V4-Flash) break the assumption:
// the provider streams ~125GB of routed-expert tensors straight from disk
// and never loads them resident (provider-swift
// ProviderCoreFoundation/ExpertStreamingAdmission.swift), so the on-disk
// total (141GB) wildly overstates the weight that must actually be loaded
// (~16GB non-expert tensors). Feeding the raw on-disk size into those gates
// makes reportedFreeForLoadAdmits (and the identical gate in
// TriggerModelSwaps/ColdSpillProviders/the warm-pool planner) reject cold
// loads on EVERY box size, including the largest — 141GB × the padding
// factor exceeds any provider's reported free-for-load headroom.
//
// The fix is registration-only: set this key to the model's true load-weight
// (raw on-disk GB of the tensors the provider actually reads resident — for
// DeepSeek-V4-Flash-4bit that is the non-`switch_mlp` tensor total, ~16GB,
// NOT `residentWeightsGb`'s 1.2×-padded figure — the coordinator's own
// coldLoadCatalogGBToMemGiB conversion already applies that padding). The
// "can this box run it at all" question stays governed by min_ram_gb, which
// modelFitsHardware already prefers over SizeGB whenever both are set — so
// this override only needs to correct the load-weight gates, not fit itself.
// See docs/reference/deepseek-v4-serving.md ("Fleet rollout").
const catalogSizeGBOverrideKey = "catalog_size_gb"

// catalogSizeGBForRow computes the SizeGB value SyncModelCatalog should
// register for a model registry row: the RuntimeParameters override when
// present and positive, else the raw on-disk manifest size
// (TotalSizeBytes/1e9) — byte-for-byte the historical behavior for every
// model that doesn't set the override.
func catalogSizeGBForRow(row store.ModelRegistryRecord) float64 {
	diskSizeGB := float64(row.ActiveVersion.TotalSizeBytes) / 1e9
	if row.RuntimeParameters == nil {
		return diskSizeGB
	}
	raw, ok := row.RuntimeParameters[catalogSizeGBOverrideKey]
	if !ok {
		return diskSizeGB
	}
	if override, ok := positiveFloat(raw); ok {
		return override
	}
	return diskSizeGB
}

// positiveFloat coerces a RuntimeParameters value (decoded from JSON as
// float64 in production, but sometimes set directly as an int/float in Go
// tests/fixtures) into a positive float64. Zero, negative, or non-numeric
// values report ok=false so callers fall back to the default.
func positiveFloat(v any) (float64, bool) {
	var f float64
	switch n := v.(type) {
	case float64:
		f = n
	case float32:
		f = float64(n)
	case int:
		f = float64(n)
	case int64:
		f = float64(n)
	default:
		return 0, false
	}
	if f <= 0 {
		return 0, false
	}
	return f, true
}
