package floorpolicy

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"math/big"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

// CohortKey keeps generation, performance tier and installed memory distinct.
// Unknown hardware never joins a catch-all cohort. Inventory records contain
// the chip marketing name, which encodes both generation and performance tier.
type CohortKey struct {
	ChipClass string  `json:"chip_class"`
	MemoryGB  float64 `json:"memory_gb"`
}

func ParseCohortKey(chip string, memoryGB float64) (CohortKey, bool) {
	if memoryGB <= 0 || math.IsNaN(memoryGB) || math.IsInf(memoryGB, 0) {
		return CohortKey{}, false
	}
	tokens := strings.Fields(strings.ToLower(chip))
	if len(tokens) > 0 && tokens[0] == "apple" {
		tokens = tokens[1:]
	}
	if len(tokens) < 1 || len(tokens) > 2 || len(tokens[0]) < 2 || tokens[0][0] != 'm' {
		return CohortKey{}, false
	}
	generation, err := strconv.Atoi(tokens[0][1:])
	if err != nil || generation <= 0 || strconv.Itoa(generation) != tokens[0][1:] {
		return CohortKey{}, false
	}
	class := "M" + strconv.Itoa(generation)
	if len(tokens) == 2 {
		switch tokens[1] {
		case "base":
		case "pro":
			class += " Pro"
		case "max":
			class += " Max"
		case "ultra":
			class += " Ultra"
		default:
			return CohortKey{}, false
		}
	}
	return CohortKey{ChipClass: class, MemoryGB: memoryGB}, true
}

// CohortBaselineValue takes the arithmetic mean of complete seven-day peer
// totals, rounding down to whole micro-USD before the existing daily-floor
// calculation. A wide accumulator avoids overflow even for a large cohort.
// Evidence retains the cohort and a reproducible fingerprint without storing
// other providers' raw machine identifiers in this financial record.
func CohortBaselineValue(key CohortKey, anchor time.Time, peers map[string]int64) (int64, string, error) {
	if len(peers) == 0 {
		return 0, "", earningsfloor.ErrHistory
	}
	anchor = anchor.UTC()
	ids := make([]string, 0, len(peers))
	var total big.Int
	for id, amount := range peers {
		if amount < 0 {
			return 0, "", earningsfloor.ErrHistory
		}
		ids = append(ids, id)
		total.Add(&total, big.NewInt(amount))
	}
	total.Quo(&total, big.NewInt(int64(len(peers))))
	slices.Sort(ids)
	digest := sha256.Sum256([]byte(strings.Join(ids, "\x00")))
	evidence, err := json.Marshal(struct {
		CohortKey
		PeerCount       int       `json:"peer_count"`
		PeerFingerprint string    `json:"peer_fingerprint_sha256"`
		WindowStart     time.Time `json:"window_start"`
		WindowEnd       time.Time `json:"window_end"`
		Statistic       string    `json:"statistic"`
	}{key, len(peers), hex.EncodeToString(digest[:]), anchor.Add(-BaselineDuration), anchor, "mean_seven_day_micro_usd_floor"})
	if err != nil {
		return 0, "", err
	}
	return total.Int64(), string(evidence), nil
}
