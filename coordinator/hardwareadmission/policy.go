package hardwareadmission

import (
	"fmt"
	"math"
	"strings"
	"time"
)

const CatalogVersion = "apple-silicon-v1"

type Mode string

const (
	ModeDisabled Mode = "disabled"
	ModeShadow   Mode = "shadow"
	ModeEnforce  Mode = "enforce"
)

type Policy struct {
	Version                    int64      `json:"version"`
	Mode                       Mode       `json:"mode"`
	MinMemoryGB                int        `json:"min_memory_gb"`
	MinMemoryBandwidthGBs      int        `json:"min_memory_bandwidth_gbs"`
	MinFP16MilliTFLOPS         int        `json:"min_fp16_millitflops"`
	CatalogVersion             string     `json:"catalog_version"`
	CreatedAt                  time.Time  `json:"created_at"`
	CreatedBy                  string     `json:"created_by,omitempty"`
	Reason                     string     `json:"reason,omitempty"`
	GrandfatherCutoffAt        *time.Time `json:"grandfather_cutoff_at,omitempty"`
	GrandfatheredProviderCount int        `json:"grandfathered_provider_count,omitempty"`
}

func DisabledPolicy() Policy {
	return Policy{Mode: ModeDisabled, CatalogVersion: CatalogVersion}
}

func ParseMode(raw string) (Mode, error) {
	mode := Mode(strings.ToLower(strings.TrimSpace(raw)))
	switch mode {
	case ModeDisabled, ModeShadow, ModeEnforce:
		return mode, nil
	default:
		return "", fmt.Errorf("hardware admission mode must be disabled, shadow, or enforce")
	}
}

func (p Policy) Validate() error {
	if _, err := ParseMode(string(p.Mode)); err != nil {
		return err
	}
	if p.MinMemoryGB < 0 || p.MinMemoryGB > 1024 {
		return fmt.Errorf("min_memory_gb must be between 0 and 1024")
	}
	if p.MinMemoryBandwidthGBs < 0 || p.MinMemoryBandwidthGBs > 10_000 {
		return fmt.Errorf("min_memory_bandwidth_gbs must be between 0 and 10000")
	}
	if p.MinFP16MilliTFLOPS < 0 || p.MinFP16MilliTFLOPS > 10_000_000 {
		return fmt.Errorf("min_fp16_millitflops must be between 0 and 10000000")
	}
	if p.CatalogVersion != "" && p.CatalogVersion != CatalogVersion {
		return fmt.Errorf("catalog_version %q is not supported by this coordinator", p.CatalogVersion)
	}
	if len(p.CreatedBy) > 200 {
		return fmt.Errorf("created_by must be at most 200 bytes")
	}
	if len(p.Reason) > 1000 {
		return fmt.Errorf("reason must be at most 1000 bytes")
	}
	return nil
}

// ValidateForActivation rejects an enforcement policy that contains no
// capacity threshold. Such a policy still checks identity, but silently admits
// every catalogued machine and is almost always a deployment typo.
func (p Policy) ValidateForActivation() error {
	if err := p.Validate(); err != nil {
		return err
	}
	if p.Mode == ModeEnforce &&
		p.MinMemoryGB == 0 &&
		p.MinMemoryBandwidthGBs == 0 &&
		p.MinFP16MilliTFLOPS == 0 {
		return fmt.Errorf("enforce mode requires at least one positive hardware threshold")
	}
	return nil
}

type Input struct {
	MachineModel string
	ChipName     string
	ChipFamily   string
	ChipTier     string
	MemoryGB     int
	GPUCores     int
}

type Observed struct {
	MachineModel       string `json:"machine_model"`
	ChipName           string `json:"chip_name"`
	ChipFamily         string `json:"chip_family"`
	ChipTier           string `json:"chip_tier"`
	MemoryGB           int    `json:"memory_gb"`
	GPUCores           int    `json:"gpu_cores"`
	MemoryBandwidthGBs int    `json:"memory_bandwidth_gbs"`
	FP16MilliTFLOPS    int    `json:"fp16_millitflops"`
	CatalogKnown       bool   `json:"catalog_known"`
}

type Failure struct {
	Code     string `json:"code"`
	Metric   string `json:"metric"`
	Observed int    `json:"observed"`
	Required int    `json:"required"`
	Unit     string `json:"unit"`
}

type Decision struct {
	Allowed         bool      `json:"allowed"`
	MeetsThresholds bool      `json:"meets_thresholds"`
	Observed        Observed  `json:"observed"`
	FailedChecks    []Failure `json:"failed_checks,omitempty"`
}

func Evaluate(policy Policy, input Input) Decision {
	spec, known := LookupChip(input.ChipFamily, input.ChipTier, input.GPUCores)
	observed := Observed{
		MachineModel: input.MachineModel,
		ChipName:     input.ChipName,
		ChipFamily:   input.ChipFamily,
		ChipTier:     input.ChipTier,
		MemoryGB:     input.MemoryGB,
		GPUCores:     input.GPUCores,
		CatalogKnown: known,
	}
	if known {
		observed.MemoryBandwidthGBs = spec.MemoryBandwidthGBs
		observed.FP16MilliTFLOPS = spec.FP16MilliTFLOPS
	}

	failures := make([]Failure, 0, 3)
	if policy.MinMemoryGB > 0 && observed.MemoryGB < policy.MinMemoryGB {
		failures = append(failures, Failure{
			Code: "memory_below_minimum", Metric: "memory_gb",
			Observed: observed.MemoryGB, Required: policy.MinMemoryGB, Unit: "GiB",
		})
	}
	if policy.MinMemoryBandwidthGBs > 0 {
		if !known {
			failures = append(failures, Failure{
				Code: "hardware_not_catalogued", Metric: "memory_bandwidth_gbs",
				Required: policy.MinMemoryBandwidthGBs, Unit: "GB/s",
			})
		} else if observed.MemoryBandwidthGBs < policy.MinMemoryBandwidthGBs {
			failures = append(failures, Failure{
				Code: "bandwidth_below_minimum", Metric: "memory_bandwidth_gbs",
				Observed: observed.MemoryBandwidthGBs, Required: policy.MinMemoryBandwidthGBs, Unit: "GB/s",
			})
		}
	}
	if policy.MinFP16MilliTFLOPS > 0 {
		if !known || observed.FP16MilliTFLOPS <= 0 {
			failures = append(failures, Failure{
				Code: "hardware_not_catalogued", Metric: "fp16_millitflops",
				Required: policy.MinFP16MilliTFLOPS, Unit: "milli-TFLOPS",
			})
		} else if observed.FP16MilliTFLOPS < policy.MinFP16MilliTFLOPS {
			failures = append(failures, Failure{
				Code: "fp16_tflops_below_minimum", Metric: "fp16_millitflops",
				Observed: observed.FP16MilliTFLOPS, Required: policy.MinFP16MilliTFLOPS, Unit: "milli-TFLOPS",
			})
		}
	}

	meets := len(failures) == 0
	allowed := policy.Mode != ModeEnforce || meets
	return Decision{
		Allowed: allowed, MeetsThresholds: meets, Observed: observed, FailedChecks: failures,
	}
}

type ChipSpec struct {
	Family             string `json:"family"`
	Tier               string `json:"tier"`
	GPUCores           int    `json:"gpu_cores"`
	MemoryBandwidthGBs int    `json:"memory_bandwidth_gbs"`
	FP16MilliTFLOPS    int    `json:"fp16_millitflops"`
	Estimate           bool   `json:"estimate"`
}

func LookupChip(family, tier string, gpuCores int) (ChipSpec, bool) {
	family = strings.ToUpper(strings.TrimSpace(family))
	tier = strings.ToLower(strings.TrimSpace(tier))
	if gpuCores <= 0 {
		return ChipSpec{}, false
	}

	bandwidth, ok := chipBandwidth(family, tier, gpuCores)
	if !ok {
		return ChipSpec{}, false
	}
	clock, ok := gpuClockGHz(family)
	if !ok {
		return ChipSpec{}, false
	}
	// FP16 vector throughput = cores × 512 FLOP/core/cycle × GHz.
	// Multiplying TFLOPS by 1000 cancels the GHz-to-Hz and tera scaling,
	// leaving cores × 512 × GHz in milli-TFLOPS.
	fp16Milli := int(math.Round(float64(gpuCores) * 512 * clock))
	return ChipSpec{
		Family: family, Tier: tier, GPUCores: gpuCores,
		MemoryBandwidthGBs: bandwidth, FP16MilliTFLOPS: fp16Milli,
		Estimate: true,
	}, true
}

func ParseChipIdentity(chipName string) (family, tier string, ok bool) {
	name := strings.ToLower(strings.TrimSpace(chipName))
	switch {
	case strings.Contains(name, "m5"):
		family = "M5"
	case strings.Contains(name, "m4"):
		family = "M4"
	case strings.Contains(name, "m3"):
		family = "M3"
	case strings.Contains(name, "m2"):
		family = "M2"
	case strings.Contains(name, "m1"):
		family = "M1"
	default:
		return "", "", false
	}
	switch {
	case strings.Contains(name, "ultra"):
		tier = "Ultra"
	case strings.Contains(name, "max"):
		tier = "Max"
	case strings.Contains(name, "pro"):
		tier = "Pro"
	default:
		tier = "Base"
	}
	return family, tier, true
}

func chipBandwidth(family, tier string, gpuCores int) (int, bool) {
	switch family + "|" + tier {
	case "M1|base":
		return 68, true
	case "M1|pro":
		return 200, true
	case "M1|max":
		return 400, true
	case "M1|ultra":
		return 800, true
	case "M2|base":
		return 100, true
	case "M2|pro":
		return 200, true
	case "M2|max":
		return 400, true
	case "M2|ultra":
		return 800, true
	case "M3|base":
		return 100, true
	case "M3|pro":
		return 150, true
	case "M3|max":
		if gpuCores >= 40 {
			return 400, true
		}
		return 300, true
	case "M3|ultra":
		return 819, true
	case "M4|base":
		return 120, true
	case "M4|pro":
		return 273, true
	case "M4|max":
		if gpuCores >= 40 {
			return 546, true
		}
		return 410, true
	case "M5|base":
		return 153, true
	case "M5|pro":
		return 307, true
	case "M5|max":
		if gpuCores >= 40 {
			return 614, true
		}
		return 460, true
	default:
		return 0, false
	}
}

func gpuClockGHz(family string) (float64, bool) {
	switch family {
	case "M1":
		return 1.28, true
	case "M2", "M3":
		return 1.40, true
	case "M4":
		return 1.80, true
	case "M5":
		return 1.90, true
	default:
		return 0, false
	}
}
