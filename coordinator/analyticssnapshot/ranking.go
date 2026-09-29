package analyticssnapshot

import (
	"errors"
	"math/big"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Snapshot) validateRankings() error {
	if len(s.Windows) != len(Windows) {
		return errors.New("analytics snapshot has incomplete windows")
	}
	for _, key := range Windows {
		w, ok := s.Windows[key]
		if !ok {
			return errors.New("analytics snapshot has incomplete windows")
		}
		if err := validateWindow(w); err != nil {
			return err
		}
	}
	return s.validateWindowNesting()
}

func validateWindow(w Window) error {
	if len(w.Leaderboards) != len(Metrics) {
		return errors.New("analytics snapshot has incomplete rankings")
	}
	if !validTotal(w.Totals) {
		return errors.New("analytics totals do not reconcile")
	}
	expected := min(w.Totals.ActiveAccounts, 200)
	common := map[string]store.LeaderboardRow{}
	for _, metric := range Metrics {
		rows, ok := w.Leaderboards[metric]
		if !ok || rows == nil || int64(len(rows)) != expected {
			return errors.New("analytics ranking missing or oversized")
		}
		if err := validateRanking(rows, metric, common); err != nil {
			return err
		}
	}
	// Each metric contains expected distinct IDs, so this also forces identical
	// complete cohorts. Larger top-200 sets may differ within the actual cohort.
	if int64(len(common)) > w.Totals.ActiveAccounts {
		return errors.New("analytics rankings exceed provider cohort")
	}
	remainingJobs := w.Totals.Jobs
	for _, row := range common {
		// Count each account once across metrics, without overflowing INT64.
		// Totals may include anonymous work, so equality is not required.
		if row.Jobs > remainingJobs {
			return errors.New("ranked job counts exceed network total")
		}
		remainingJobs -= row.Jobs
	}
	return nil
}

func validateRanking(rows []store.LeaderboardRow, metric string, common map[string]store.LeaderboardRow) error {
	seen := map[string]bool{}
	for _, r := range rows {
		if r.AccountID == "" || len(r.AccountID) > 512 || seen[r.AccountID] || r.Jobs < 0 || !sumMatches(r.EarningsMicroUSD, r.WorkEarningsMicroUSD, r.RewardEarningsMicroUSD) {
			return errors.New("analytics ranking does not reconcile")
		}
		if prior, ok := common[r.AccountID]; ok && prior != r {
			return errors.New("analytics metrics disagree on account totals")
		}
		common[r.AccountID] = r
		seen[r.AccountID] = true
	}
	if !sort.SliceIsSorted(rows, func(i, j int) bool {
		a, b := rankValue(rows[i], metric), rankValue(rows[j], metric)
		if a == b {
			return rows[i].AccountID < rows[j].AccountID
		}
		return a > b
	}) {
		return errors.New("analytics ranking is unordered")
	}
	return nil
}

func sumMatches(total, a, b int64) bool {
	return new(big.Int).Add(big.NewInt(a), big.NewInt(b)).Cmp(big.NewInt(total)) == 0
}
func validTotal(t store.NetworkTotalsRow) bool {
	return t.Jobs >= 0 && t.ActiveAccounts >= 0 && sumMatches(t.EarningsMicroUSD, t.WorkEarningsMicroUSD, t.RewardEarningsMicroUSD)
}
func rankValue(r store.LeaderboardRow, metric string) int64 {
	switch metric {
	case "tokens":
		return r.Tokens
	case "jobs":
		return r.Jobs
	default:
		return r.EarningsMicroUSD
	}
}
