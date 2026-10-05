package analyticssnapshot

import "errors"

// Every window in Windows ends at the same source cut. Jobs and distinct
// provider accounts are nonnegative counts, so widening that interval cannot
// lower either count. A listed account's job count obeys the same rule when it
// appears in both top-200 results; an absent account may simply be unranked
// only when the wider cohort is truncated.
func (s *Snapshot) validateWindowNesting() error {
	for i := 1; i < len(Windows); i++ {
		narrow, wider := s.Windows[Windows[i-1]], s.Windows[Windows[i]]
		if wider.Totals.Jobs < narrow.Totals.Jobs || wider.Totals.ActiveAccounts < narrow.Totals.ActiveAccounts {
			return errors.New("analytics counts decrease in a wider window")
		}
		narrowJobs := make(map[string]int64)
		for _, metric := range Metrics {
			for _, row := range narrow.Leaderboards[metric] {
				narrowJobs[row.AccountID] = row.Jobs
			}
		}
		for _, metric := range Metrics {
			for _, row := range wider.Leaderboards[metric] {
				if jobs, listed := narrowJobs[row.AccountID]; listed && row.Jobs < jobs {
					return errors.New("analytics account jobs decrease in a wider window")
				}
				delete(narrowJobs, row.AccountID)
			}
		}
		if wider.Totals.ActiveAccounts <= 200 && len(narrowJobs) != 0 {
			return errors.New("analytics account missing from complete wider cohort")
		}
	}
	return nil
}
