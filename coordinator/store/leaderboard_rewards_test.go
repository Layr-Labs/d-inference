package store

import (
	"testing"
	"time"
)

// seedLeaderboardFixture populates a MemoryStore with a mix of work-only,
// reward-only, combined, and non-reward-credit accounts so the leaderboard and
// network-totals reward differentiation can be exercised end to end.
//
// Resulting per-account shape (all-time):
//
//	alice  work=1000  tokens=150 jobs=1  reward=0     total=1000  (provider)
//	bob    reward=2000 but NO work  -> NOT a provider -> absent from leaderboard
//	carol  work=500   tokens=15  jobs=1  reward=700   total=1200  (provider, combined)
//	dave   work=0     tokens=0   jobs=0  reward=900   total=900   (base reward only provider)
//	frank  work=300   tokens=30  jobs=1  reward=0     total=300   (provider; +admin_credit ignored)
//	eve    admin_credit only, no work -> absent
func seedLeaderboardFixture(t *testing.T) *MemoryStore {
	t.Helper()
	s := NewMemory(Config{})
	now := time.Now()

	// alice: inference work only.
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID:        "acct-alice",
		AmountMicroUSD:   1000,
		PromptTokens:     100,
		CompletionTokens: 50,
		CreatedAt:        now,
	}); err != nil {
		t.Fatalf("record alice earning: %v", err)
	}

	// bob: reward only (referral_reward), no inference work.
	if err := s.CreditWithdrawable("acct-bob", 2000, LedgerReferralReward, "ref-bob"); err != nil {
		t.Fatalf("credit bob reward: %v", err)
	}

	// carol: combined work + admin_reward.
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID:        "acct-carol",
		AmountMicroUSD:   500,
		PromptTokens:     10,
		CompletionTokens: 5,
		CreatedAt:        now,
	}); err != nil {
		t.Fatalf("record carol earning: %v", err)
	}
	if err := s.CreditWithdrawable("acct-carol", 700, LedgerAdminReward, "ref-carol"); err != nil {
		t.Fatalf("credit carol reward: %v", err)
	}

	// dave: base reward only. It is visible in provider_earnings with
	// model=base_reward, but must count as reward rather than inference work.
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID:      "acct-dave",
		Model:          "base_reward",
		AmountMicroUSD: 900,
		CreatedAt:      now,
	}); err != nil {
		t.Fatalf("record dave base reward: %v", err)
	}

	// frank: work + a non-reward admin_credit that must NOT count as reward.
	if err := s.RecordProviderEarning(&ProviderEarning{
		AccountID:        "acct-frank",
		AmountMicroUSD:   300,
		PromptTokens:     20,
		CompletionTokens: 10,
		CreatedAt:        now,
	}); err != nil {
		t.Fatalf("record frank earning: %v", err)
	}
	if err := s.Credit("acct-frank", 8000, LedgerAdminCredit, "ref-frank"); err != nil {
		t.Fatalf("credit frank admin_credit: %v", err)
	}

	// eve: admin_credit only — non-withdrawable consumer credit, not an earning.
	if err := s.Credit("acct-eve", 5000, LedgerAdminCredit, "ref-eve"); err != nil {
		t.Fatalf("credit eve admin_credit: %v", err)
	}

	return s
}

func findRow(rows []LeaderboardRow, accountID string) (LeaderboardRow, bool) {
	for _, r := range rows {
		if r.AccountID == accountID {
			return r, true
		}
	}
	return LeaderboardRow{}, false
}

func TestLeaderboardWorkRewardDifferentiation(t *testing.T) {
	s := seedLeaderboardFixture(t)
	rows := s.Leaderboard(LeaderboardEarnings, time.Time{}, 50)

	cases := []struct {
		name             string
		accountID        string
		present          bool
		work, reward     int64
		earnings, tokens int64
		jobs             int64
	}{
		{name: "work-only", accountID: "acct-alice", present: true, work: 1000, reward: 0, earnings: 1000, tokens: 150, jobs: 1},
		{name: "reward-only-non-provider-absent", accountID: "acct-bob", present: false},
		{name: "combined", accountID: "acct-carol", present: true, work: 500, reward: 700, earnings: 1200, tokens: 15, jobs: 1},
		{name: "base-reward-provider", accountID: "acct-dave", present: true, work: 0, reward: 900, earnings: 900, tokens: 0, jobs: 0},
		{name: "work-plus-nonreward-credit", accountID: "acct-frank", present: true, work: 300, reward: 0, earnings: 300, tokens: 30, jobs: 1},
		{name: "credit-only-absent", accountID: "acct-eve", present: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, ok := findRow(rows, tc.accountID)
			if ok != tc.present {
				t.Fatalf("present = %v, want %v (row=%+v)", ok, tc.present, r)
			}
			if !tc.present {
				return
			}
			if r.WorkEarningsMicroUSD != tc.work {
				t.Errorf("WorkEarningsMicroUSD = %d, want %d", r.WorkEarningsMicroUSD, tc.work)
			}
			if r.RewardEarningsMicroUSD != tc.reward {
				t.Errorf("RewardEarningsMicroUSD = %d, want %d", r.RewardEarningsMicroUSD, tc.reward)
			}
			if r.EarningsMicroUSD != tc.earnings {
				t.Errorf("EarningsMicroUSD = %d, want %d (work+reward)", r.EarningsMicroUSD, tc.earnings)
			}
			if r.EarningsMicroUSD != r.WorkEarningsMicroUSD+r.RewardEarningsMicroUSD {
				t.Errorf("EarningsMicroUSD %d != work %d + reward %d", r.EarningsMicroUSD, r.WorkEarningsMicroUSD, r.RewardEarningsMicroUSD)
			}
			if r.Tokens != tc.tokens {
				t.Errorf("Tokens = %d, want %d", r.Tokens, tc.tokens)
			}
			if r.Jobs != tc.jobs {
				t.Errorf("Jobs = %d, want %d", r.Jobs, tc.jobs)
			}
		})
	}
}

// TestLeaderboardRankingUsesTotal verifies the earnings metric ranks by the
// combined total: carol's reward lifts her total above alice even though alice
// has strictly more *work* earnings. Reward-only bob is excluded (not a provider).
func TestLeaderboardRankingUsesTotal(t *testing.T) {
	s := seedLeaderboardFixture(t)
	rows := s.Leaderboard(LeaderboardEarnings, time.Time{}, 50)

	wantOrder := []string{"acct-carol", "acct-alice", "acct-dave", "acct-frank"}
	if len(rows) != len(wantOrder) {
		t.Fatalf("got %d rows, want %d: %+v", len(rows), len(wantOrder), rows)
	}
	for i, want := range wantOrder {
		if rows[i].AccountID != want {
			t.Errorf("rank %d = %s, want %s (rows=%+v)", i+1, rows[i].AccountID, want, rows)
		}
	}
	// carol's reward (700) lifts her total (1200) above alice's work-only total
	// (1000); by work alone carol (500) would rank below alice (1000).
	carol, _ := findRow(rows, "acct-carol")
	alice, _ := findRow(rows, "acct-alice")
	if !(carol.EarningsMicroUSD > alice.EarningsMicroUSD) {
		t.Errorf("expected carol total %d > alice total %d", carol.EarningsMicroUSD, alice.EarningsMicroUSD)
	}
	if !(carol.WorkEarningsMicroUSD < alice.WorkEarningsMicroUSD) {
		t.Errorf("expected carol work %d < alice work %d (so reward drives the ranking)", carol.WorkEarningsMicroUSD, alice.WorkEarningsMicroUSD)
	}
}

// TestLeaderboardTokensAndJobsMetrics verifies the non-earnings metrics still
// rank by work-derived tokens/jobs, with a deterministic account_id tiebreaker.
func TestLeaderboardTokensAndJobsMetrics(t *testing.T) {
	s := seedLeaderboardFixture(t)

	tokens := s.Leaderboard(LeaderboardTokens, time.Time{}, 50)
	wantTokenOrder := []string{"acct-alice", "acct-frank", "acct-carol", "acct-dave"}
	for i, want := range wantTokenOrder {
		if i >= len(tokens) || tokens[i].AccountID != want {
			t.Fatalf("tokens rank %d = %v, want %s (rows=%+v)", i+1, rowID(tokens, i), want, tokens)
		}
	}

	jobs := s.Leaderboard(LeaderboardJobs, time.Time{}, 50)
	// alice/carol/frank all have 1 job -> tiebreak by account_id asc; reward-only
	// bob is not a provider and is excluded; dave has 0 jobs so sorts after the
	// work providers.
	wantJobOrder := []string{"acct-alice", "acct-carol", "acct-frank", "acct-dave"}
	for i, want := range wantJobOrder {
		if i >= len(jobs) || jobs[i].AccountID != want {
			t.Fatalf("jobs rank %d = %v, want %s (rows=%+v)", i+1, rowID(jobs, i), want, jobs)
		}
	}
}

func rowID(rows []LeaderboardRow, i int) string {
	if i < 0 || i >= len(rows) {
		return "<none>"
	}
	return rows[i].AccountID
}

func TestLeaderboardLimitClamp(t *testing.T) {
	s := seedLeaderboardFixture(t)
	// limit<=0 and limit>200 both clamp to 50 (>= our 4 provider rows), so all appear.
	if got := s.Leaderboard(LeaderboardEarnings, time.Time{}, 0); len(got) != 4 {
		t.Errorf("limit 0 -> %d rows, want 4", len(got))
	}
	if got := s.Leaderboard(LeaderboardEarnings, time.Time{}, 1000); len(got) != 4 {
		t.Errorf("limit 1000 -> %d rows, want 4", len(got))
	}
	// A real positive limit truncates after sorting.
	if got := s.Leaderboard(LeaderboardEarnings, time.Time{}, 2); len(got) != 2 {
		t.Fatalf("limit 2 -> %d rows, want 2", len(got))
	} else if got[0].AccountID != "acct-carol" || got[1].AccountID != "acct-alice" {
		t.Errorf("limit 2 top rows = %s,%s want acct-carol,acct-alice", got[0].AccountID, got[1].AccountID)
	}
}

func TestNetworkTotalsWorkRewardDifferentiation(t *testing.T) {
	s := seedLeaderboardFixture(t)
	totals := s.NetworkTotals(time.Time{})

	const (
		wantWork     = int64(1800) // alice 1000 + carol 500 + frank 300
		wantReward   = int64(1600) // carol 700 + dave base_reward 900; bob's 2000 excluded
		wantEarnings = wantWork + wantReward
		wantTokens   = int64(195) // 150 + 15 + 30
		wantJobs     = int64(3)   // alice, carol, frank
		wantAccounts = int64(4)   // alice, carol, dave, frank (bob reward-only + eve credit-only excluded)
	)

	if totals.WorkEarningsMicroUSD != wantWork {
		t.Errorf("WorkEarningsMicroUSD = %d, want %d", totals.WorkEarningsMicroUSD, wantWork)
	}
	if totals.RewardEarningsMicroUSD != wantReward {
		t.Errorf("RewardEarningsMicroUSD = %d, want %d", totals.RewardEarningsMicroUSD, wantReward)
	}
	if totals.EarningsMicroUSD != wantEarnings {
		t.Errorf("EarningsMicroUSD = %d, want %d (work+reward)", totals.EarningsMicroUSD, wantEarnings)
	}
	if totals.EarningsMicroUSD != totals.WorkEarningsMicroUSD+totals.RewardEarningsMicroUSD {
		t.Errorf("EarningsMicroUSD %d != work %d + reward %d", totals.EarningsMicroUSD, totals.WorkEarningsMicroUSD, totals.RewardEarningsMicroUSD)
	}
	if totals.Tokens != wantTokens {
		t.Errorf("Tokens = %d, want %d", totals.Tokens, wantTokens)
	}
	if totals.Jobs != wantJobs {
		t.Errorf("Jobs = %d, want %d", totals.Jobs, wantJobs)
	}
	if totals.ActiveAccounts != wantAccounts {
		t.Errorf("ActiveAccounts = %d, want %d (providers only: exclude reward-only bob and credit-only eve)", totals.ActiveAccounts, wantAccounts)
	}
}

// TestLeaderboardExcludesNonProviderRewards verifies rewards are only credited
// to providers (accounts with inference work). A non-provider that only earned
// referral/admin rewards must NOT appear on the provider leaderboard, and its
// rewards must be excluded from network totals — while a real provider's reward
// is still counted.
func TestLeaderboardExcludesNonProviderRewards(t *testing.T) {
	s := NewMemory(Config{})
	// A provider who also earned an admin reward.
	if err := s.RecordProviderEarning(&ProviderEarning{AccountID: "prov", AmountMicroUSD: 100, PromptTokens: 4, CompletionTokens: 6, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("record prov earning: %v", err)
	}
	if err := s.CreditWithdrawable("prov", 50, LedgerAdminReward, "r1"); err != nil {
		t.Fatalf("credit prov reward: %v", err)
	}
	// A non-provider who only earned referral + admin rewards (never served).
	if err := s.CreditWithdrawable("consumer", 900, LedgerReferralReward, "r2"); err != nil {
		t.Fatalf("credit consumer referral: %v", err)
	}
	if err := s.CreditWithdrawable("consumer", 98, LedgerAdminReward, "r3"); err != nil {
		t.Fatalf("credit consumer admin reward: %v", err)
	}

	rows := s.Leaderboard(LeaderboardEarnings, time.Time{}, 50)
	if _, ok := findRow(rows, "consumer"); ok {
		t.Errorf("non-provider 'consumer' must not appear on the provider leaderboard")
	}
	prov, ok := findRow(rows, "prov")
	if !ok {
		t.Fatalf("provider 'prov' missing from leaderboard: %+v", rows)
	}
	if prov.WorkEarningsMicroUSD != 100 || prov.RewardEarningsMicroUSD != 50 || prov.EarningsMicroUSD != 150 {
		t.Errorf("prov = work %d reward %d total %d, want 100/50/150", prov.WorkEarningsMicroUSD, prov.RewardEarningsMicroUSD, prov.EarningsMicroUSD)
	}

	tot := s.NetworkTotals(time.Time{})
	if tot.RewardEarningsMicroUSD != 50 {
		t.Errorf("network reward = %d, want 50 (consumer's 998 excluded)", tot.RewardEarningsMicroUSD)
	}
	if tot.EarningsMicroUSD != 150 {
		t.Errorf("network earnings = %d, want 150", tot.EarningsMicroUSD)
	}
	if tot.ActiveAccounts != 1 {
		t.Errorf("active accounts = %d, want 1 (only the provider)", tot.ActiveAccounts)
	}
}

// TestNetworkTotalsExcludesNonRewardLedgerTypes confirms a store containing only
// non-reward ledger entries (admin_credit / invite_credit) reports zero reward
// earnings and zero active accounts.
func TestNetworkTotalsExcludesNonRewardLedgerTypes(t *testing.T) {
	s := NewMemory(Config{})
	if err := s.Credit("acct-x", 1234, LedgerAdminCredit, "x"); err != nil {
		t.Fatalf("credit admin_credit: %v", err)
	}
	if err := s.Credit("acct-y", 5678, LedgerInviteCredit, "y"); err != nil {
		t.Fatalf("credit invite_credit: %v", err)
	}

	totals := s.NetworkTotals(time.Time{})
	if totals.RewardEarningsMicroUSD != 0 {
		t.Errorf("RewardEarningsMicroUSD = %d, want 0", totals.RewardEarningsMicroUSD)
	}
	if totals.EarningsMicroUSD != 0 {
		t.Errorf("EarningsMicroUSD = %d, want 0", totals.EarningsMicroUSD)
	}
	if totals.ActiveAccounts != 0 {
		t.Errorf("ActiveAccounts = %d, want 0", totals.ActiveAccounts)
	}

	if rows := s.Leaderboard(LeaderboardEarnings, time.Time{}, 50); len(rows) != 0 {
		t.Errorf("Leaderboard returned %d rows, want 0 (non-reward ledger types only): %+v", len(rows), rows)
	}
}

// TestIsRewardLedgerType pins the exact set of ledger types counted as rewards.
func TestIsRewardLedgerType(t *testing.T) {
	reward := []LedgerEntryType{LedgerReferralReward, LedgerAdminReward}
	for _, lt := range reward {
		if !IsRewardLedgerType(lt) {
			t.Errorf("IsRewardLedgerType(%q) = false, want true", lt)
		}
	}
	notReward := []LedgerEntryType{
		LedgerDeposit, LedgerCharge, LedgerPayout, LedgerPlatformFee, LedgerWithdrawal,
		LedgerStripeDeposit, LedgerStripePayout, LedgerInviteCredit, LedgerRefund,
		LedgerAdminCredit, LedgerMigration,
	}
	for _, lt := range notReward {
		if IsRewardLedgerType(lt) {
			t.Errorf("IsRewardLedgerType(%q) = true, want false", lt)
		}
	}
	if len(RewardLedgerTypes) != 2 {
		t.Errorf("RewardLedgerTypes has %d entries, want 2", len(RewardLedgerTypes))
	}
}
