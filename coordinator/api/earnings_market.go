package api

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const earningsMarketWindow = 30 * 24 * time.Hour

type earningsMarketModel struct {
	ID                          string  `json:"id"`
	DisplayName                 string  `json:"display_name"`
	MinRAMGB                    int     `json:"min_ram_gb"`
	SizeBytes                   int64   `json:"size_bytes"`
	SizeGB                      float64 `json:"size_gb"`
	WorkPayoutMicroUSD          int64   `json:"work_payout_micro_usd"`
	PaidTokens                  int64   `json:"paid_tokens"`
	PaidJobs                    int64   `json:"paid_jobs"`
	AggregateTPS                float64 `json:"aggregate_tps"`
	AggregateMemoryBandwidthGBs float64 `json:"aggregate_memory_bandwidth_gbps"`
	BenchmarkTPS                float64 `json:"benchmark_tps"`
	BenchmarkMemoryBandwidthGBs float64 `json:"benchmark_memory_bandwidth_gbps"`
	ProviderSupply              int     `json:"provider_supply"`
	EstimateAvailable           bool    `json:"estimate_available"`
	UnavailableReason           string  `json:"unavailable_reason,omitempty"`
}

type earningsMarketAudit struct {
	TotalSettledWorkMicroUSD int64 `json:"total_settled_work_micro_usd"`
	ModeledWorkMicroUSD      int64 `json:"modeled_work_micro_usd"`
	UnattributedWorkMicroUSD int64 `json:"unattributed_work_micro_usd"`
	TotalPaidTokens          int64 `json:"total_paid_tokens"`
	ModeledPaidTokens        int64 `json:"modeled_paid_tokens"`
	UnattributedPaidTokens   int64 `json:"unattributed_paid_tokens"`
	TotalPaidJobs            int64 `json:"total_paid_jobs"`
	ModeledPaidJobs          int64 `json:"modeled_paid_jobs"`
	UnattributedPaidJobs     int64 `json:"unattributed_paid_jobs"`
}

type earningsMarketBaseRewards struct {
	Enabled             bool               `json:"enabled"`
	MonthlyPoolMicroUSD int64              `json:"monthly_pool_micro_usd"`
	MinUptimeFraction   float64            `json:"min_uptime_fraction"`
	ReductionK          float64            `json:"reduction_k"`
	AccountCapFraction  float64            `json:"account_cap_fraction"`
	Tiers               []baserewards.Tier `json:"tiers"`
}

type earningsMarketResponse struct {
	WindowStart time.Time                 `json:"window_start"`
	WindowEnd   time.Time                 `json:"window_end"`
	WindowDays  int                       `json:"window_days"`
	Models      []earningsMarketModel     `json:"models"`
	Audit       earningsMarketAudit       `json:"audit"`
	BaseRewards earningsMarketBaseRewards `json:"base_rewards"`
}

// handleEarningsMarket serves the one calculator-ready market snapshot used by
// both the console and static landing page. Work demand comes only from settled
// provider earnings; capacity comes only from the live routable registry.
func (s *Server) handleEarningsMarket(w http.ResponseWriter, _ *http.Request) {
	const cacheKey = "earnings_market:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	windowEnd := time.Now().UTC()
	windowStart := windowEnd.Add(-earningsMarketWindow)

	records, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.writeEarningsMarketFailure(w, "list active model registry", err)
		return
	}
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.writeEarningsMarketFailure(w, "list model aliases", err)
		return
	}
	work, err := s.store.ModelSettledWorkTotals(windowStart, windowEnd)
	if err != nil {
		s.writeEarningsMarketFailure(w, "aggregate settled work", err)
		return
	}

	response, err := buildEarningsMarketResponse(
		records,
		aliases,
		s.registry.ModelCapacitySnapshot(),
		work,
		windowStart,
		windowEnd,
		s.baseRewardsConfig,
	)
	if err != nil {
		s.writeEarningsMarketFailure(w, "build market snapshot", err)
		return
	}
	body, err := json.Marshal(response)
	if err != nil {
		s.writeEarningsMarketFailure(w, "encode market snapshot", err)
		return
	}
	s.readCache.Set(cacheKey, body, 5*time.Minute)
	writeCachedJSON(w, body)
}

func (s *Server) writeEarningsMarketFailure(w http.ResponseWriter, operation string, err error) {
	s.logger.Error("earnings market unavailable", "operation", operation, "error", err)
	writeJSON(w, http.StatusInternalServerError, errorResponse(
		"internal_error",
		"earnings market is temporarily unavailable",
	))
}

func buildEarningsMarketResponse(
	records []store.ModelRegistryRecord,
	aliases []store.ModelAlias,
	capacities []registry.ModelCapacity,
	work []store.ModelSettledWorkTotal,
	windowStart, windowEnd time.Time,
	baseRewardsConfig BaseRewardsConfig,
) (earningsMarketResponse, error) {
	if err := validateEarningsBaseRewardsConfig(baseRewardsConfig); err != nil {
		return earningsMarketResponse{}, err
	}
	capacityByModel := make(map[string]registry.ModelCapacity, len(capacities))
	for _, capacity := range capacities {
		if err := validateEarningsCapacity(capacity); err != nil {
			return earningsMarketResponse{}, err
		}
		if _, duplicate := capacityByModel[capacity.ModelID]; duplicate {
			return earningsMarketResponse{}, fmt.Errorf("duplicate live capacity for model %q", capacity.ModelID)
		}
		capacityByModel[capacity.ModelID] = capacity
	}
	catalog, err := buildEarningsCatalog(records, aliases)
	if err != nil {
		return earningsMarketResponse{}, err
	}

	modelIndex := make(map[string]int, len(catalog))
	models := make([]earningsMarketModel, len(catalog))
	for i, entry := range catalog {
		model := entry.model
		for _, member := range entry.capacityMembers {
			if capacity, ok := capacityByModel[member]; ok {
				model.AggregateTPS += capacity.AggregateTPS
				model.AggregateMemoryBandwidthGBs += capacity.AggregateMemoryBandwidthGBs
				model.BenchmarkTPS += capacity.BenchmarkTPS
				model.BenchmarkMemoryBandwidthGBs += capacity.BenchmarkMemoryBandwidthGBs
				model.ProviderSupply += capacity.EligibleProviders
			}
		}
		models[i] = model
		modelIndex[model.ID] = i
	}

	var audit earningsMarketAudit
	for _, total := range work {
		paidTokens := total.PaidTokens()
		audit.TotalSettledWorkMicroUSD += total.WorkPayoutMicroUSD
		audit.TotalPaidTokens += paidTokens
		audit.TotalPaidJobs += total.Jobs

		index, ok := modelIndex[total.PublicModel]
		if !ok {
			continue
		}
		models[index].WorkPayoutMicroUSD += total.WorkPayoutMicroUSD
		models[index].PaidTokens += paidTokens
		models[index].PaidJobs += total.Jobs
		audit.ModeledWorkMicroUSD += total.WorkPayoutMicroUSD
		audit.ModeledPaidTokens += paidTokens
		audit.ModeledPaidJobs += total.Jobs
	}
	audit.UnattributedWorkMicroUSD = audit.TotalSettledWorkMicroUSD - audit.ModeledWorkMicroUSD
	audit.UnattributedPaidTokens = audit.TotalPaidTokens - audit.ModeledPaidTokens
	audit.UnattributedPaidJobs = audit.TotalPaidJobs - audit.ModeledPaidJobs

	for i := range models {
		models[i].EstimateAvailable, models[i].UnavailableReason = earningsEstimateAvailability(models[i])
	}

	return earningsMarketResponse{
		WindowStart: windowStart,
		WindowEnd:   windowEnd,
		WindowDays:  int(earningsMarketWindow / (24 * time.Hour)),
		Models:      models,
		Audit:       audit,
		BaseRewards: earningsMarketBaseRewards{
			Enabled:             baseRewardsConfig.Enabled,
			MonthlyPoolMicroUSD: baseRewardsConfig.FloorPoolB,
			MinUptimeFraction:   baseRewardsConfig.MinUptimeFrac,
			ReductionK:          baseRewardsConfig.ReductionK,
			AccountCapFraction:  baseRewardsConfig.AccountCapFrac,
			Tiers:               baserewards.Tiers(),
		},
	}, nil
}

func validateEarningsBaseRewardsConfig(config BaseRewardsConfig) error {
	if config.FloorPoolB < 0 ||
		config.MinUptimeFrac < 0 || config.MinUptimeFrac > 1 ||
		math.IsNaN(config.MinUptimeFrac) || math.IsInf(config.MinUptimeFrac, 0) ||
		config.ReductionK < 0 || math.IsNaN(config.ReductionK) || math.IsInf(config.ReductionK, 0) ||
		config.AccountCapFrac < 0 || config.AccountCapFrac > 1 ||
		math.IsNaN(config.AccountCapFrac) || math.IsInf(config.AccountCapFrac, 0) {
		return fmt.Errorf("invalid base reward policy")
	}
	return nil
}

func earningsEstimateAvailability(model earningsMarketModel) (bool, string) {
	if model.WorkPayoutMicroUSD <= 0 || model.PaidTokens <= 0 || model.PaidJobs <= 0 {
		return false, "settled_work_unavailable"
	}
	if model.AggregateTPS <= 0 || model.ProviderSupply <= 0 {
		return false, "competing_capacity_unavailable"
	}
	if model.BenchmarkTPS <= 0 || model.BenchmarkMemoryBandwidthGBs <= 0 {
		return false, "throughput_benchmark_unavailable"
	}
	return true, ""
}
