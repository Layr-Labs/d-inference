package api

import (
	"fmt"
	"math"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type earningsCatalogModel struct {
	model                 earningsMarketModel
	candidateMember       string
	routingFallbackMember string
}

// buildEarningsCatalog collapses each active standard alias's full historical
// lineage into one public calculator row. Candidate metadata comes from Desired
// when active because new providers converge there. Live competing capacity can
// fall back to Previous when Desired has no eligible provider, matching alias
// routing. Historical work is attributed separately by public identity.
func buildEarningsCatalog(
	records []store.ModelRegistryRecord,
	aliases []store.ModelAlias,
) ([]earningsCatalogModel, error) {
	recordsByID := make(map[string]store.ModelRegistryRecord, len(records))
	for _, record := range records {
		if record.ID == "" || record.ActiveVersion == nil || record.ActiveVersion.TotalSizeBytes <= 0 ||
			record.MinRAMGB <= 0 {
			return nil, fmt.Errorf("active model %q is missing calculator metadata", record.ID)
		}
		if _, duplicate := recordsByID[record.ID]; duplicate {
			return nil, fmt.Errorf("duplicate active model %q", record.ID)
		}
		recordsByID[record.ID] = record
	}

	sort.Slice(aliases, func(i, j int) bool { return aliases[i].AliasID < aliases[j].AliasID })
	hiddenBuilds := make(map[string]struct{})
	publicAliasIDs := make(map[string]struct{})
	openRouterAliasIDs := make(map[string]struct{})
	out := make([]earningsCatalogModel, 0, len(records))

	for _, alias := range aliases {
		if alias.OpenRouterOnly && alias.AliasID != "" {
			openRouterAliasIDs[alias.AliasID] = struct{}{}
		}
	}

	for _, alias := range aliases {
		if !alias.Active || alias.OpenRouterOnly || alias.AliasID == "" {
			continue
		}
		historyMembers := uniqueNonemptyStrings(append(
			[]string{alias.AliasID, alias.DesiredBuild, alias.PreviousBuild},
			alias.RetiredBuilds...,
		))
		for _, member := range historyMembers {
			if member != alias.AliasID {
				hiddenBuilds[member] = struct{}{}
			}
		}
		publicAliasIDs[alias.AliasID] = struct{}{}

		candidateMember, routingFallbackMember, ok := activeAliasTargets(alias, recordsByID)
		if !ok {
			continue
		}
		primary := recordsByID[candidateMember]
		displayName := alias.DisplayName
		if displayName == "" {
			displayName = primary.DisplayName
		}
		if displayName == "" {
			displayName = alias.AliasID
		}
		out = append(out, earningsCatalogModel{
			model: earningsMarketModel{
				ID:          alias.AliasID,
				DisplayName: displayName,
				MinRAMGB:    primary.MinRAMGB,
				SizeBytes:   primary.ActiveVersion.TotalSizeBytes,
				SizeGB:      float64(primary.ActiveVersion.TotalSizeBytes) / 1_000_000_000,
			},
			candidateMember:       candidateMember,
			routingFallbackMember: routingFallbackMember,
		})
	}

	sort.Slice(records, func(i, j int) bool { return records[i].ID < records[j].ID })
	for _, record := range records {
		if _, openRouterOnly := openRouterAliasIDs[record.ID]; openRouterOnly {
			continue
		}
		if _, isAlias := publicAliasIDs[record.ID]; isAlias {
			continue
		}
		if _, hidden := hiddenBuilds[record.ID]; hidden {
			continue
		}
		displayName := record.DisplayName
		if displayName == "" {
			displayName = record.ID
		}
		out = append(out, earningsCatalogModel{
			model: earningsMarketModel{
				ID:          record.ID,
				DisplayName: displayName,
				MinRAMGB:    record.MinRAMGB,
				SizeBytes:   record.ActiveVersion.TotalSizeBytes,
				SizeGB:      float64(record.ActiveVersion.TotalSizeBytes) / 1_000_000_000,
			},
			candidateMember: record.ID,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].model.ID < out[j].model.ID })
	return out, nil
}

func activeAliasTargets(
	alias store.ModelAlias,
	recordsByID map[string]store.ModelRegistryRecord,
) (candidate, routingFallback string, ok bool) {
	for _, build := range []string{alias.DesiredBuild, alias.PreviousBuild} {
		if build == "" {
			continue
		}
		if _, active := recordsByID[build]; active {
			if candidate == "" {
				candidate = build
				continue
			}
			if build != candidate {
				routingFallback = build
			}
			break
		}
	}
	return candidate, routingFallback, candidate != ""
}

func uniqueNonemptyStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, duplicate := seen[value]; duplicate {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

func validateEarningsCapacity(capacity registry.ModelCapacity) error {
	values := []float64{
		capacity.AggregateTPS,
		capacity.AggregateMemoryBandwidthGBs,
		capacity.BenchmarkTPS,
		capacity.BenchmarkMemoryBandwidthGBs,
	}
	for _, value := range values {
		if value < 0 || math.IsNaN(value) || math.IsInf(value, 0) {
			return fmt.Errorf("model %q has invalid live capacity", capacity.ModelID)
		}
	}
	if capacity.ModelID == "" || capacity.EligibleProviders < 0 ||
		capacity.ObservedBenchmarkProviders < 0 ||
		capacity.ObservedBenchmarkProviders > capacity.EligibleProviders {
		return fmt.Errorf("model %q has invalid live capacity", capacity.ModelID)
	}
	return nil
}
