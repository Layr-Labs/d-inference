package baserewards

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type reallocatingEngineStore struct {
	*engineStore
	plans [][]store.FloorDrawBatchItem
	check func(plan, index, pass int)
}

func (s *reallocatingEngineStore) SettleProviderFloorDrawBatch(ctx context.Context, items []store.FloorDrawBatchItem, authorize func(int) bool) (store.FloorDrawBatchResult, error) {
	s.plans = append(s.plans, append([]store.FloorDrawBatchItem(nil), items...))
	plan := len(s.plans)
	checks := make(map[int]int)
	return s.inner.SettleProviderFloorDrawBatch(ctx, items, func(index int) bool {
		checks[index]++
		if s.check != nil {
			s.check(plan, index, checks[index])
		}
		return authorize(index)
	})
}

func rewardPlanAmounts(items []store.FloorDrawBatchItem) map[string]int64 {
	amounts := make(map[string]int64)
	for _, item := range items {
		amounts[item.Draw.ProviderKey] = item.Draw.AmountMicroUSD
	}
	return amounts
}

func TestRewardPlanReallocatesLateLossWithoutFreezingPartialOrZeroRows(t *testing.T) {
	for _, test := range []struct {
		name         string
		budget       int64
		reserve, cap float64
		prior        int64
		keys         []string
		memory       []int
		accounts     []string
		earned       []int64
		first, final map[string]int64
	}{
		{name: "partial-and-zero-before-full", budget: 3016, keys: []string{"a-wait", "b-partial", "z-full"}, memory: []int{64, 64, 64}, accounts: []string{"a", "b", "z"}, earned: []int64{1000, 500, 0}, first: map[string]int64{"a-wait": 0, "b-partial": 1000, "z-full": 2016}, final: map[string]int64{"a-wait": 1000, "b-partial": 2016}},
		{name: "two-partial-grants", budget: 1000, reserve: 0.5, keys: []string{"a-nonworkhorse", "z-workhorse"}, memory: []int{32, 64}, accounts: []string{"a", "z"}, earned: []int64{0, 2016}, first: map[string]int64{"a-nonworkhorse": 500, "z-workhorse": 500}, final: map[string]int64{"a-nonworkhorse": 1000}},
		{name: "account-cap-reused-with-prior-credit", budget: 2000, cap: 0.5, prior: 200, keys: []string{"a-alternative", "b-other", "z-preferred"}, memory: []int{64, 64, 64}, accounts: []string{"shared", "other", "shared"}, earned: []int64{500, 100, 0}, first: map[string]int64{"a-alternative": 0, "b-other": 1000, "z-preferred": 800}, final: map[string]int64{"a-alternative": 800, "b-other": 1000, "historical": 200}},
	} {
		t.Run(test.name, func(t *testing.T) {
			epoch, start, end, clock := closedEpoch()
			st := &reallocatingEngineStore{engineStore: newEngineStore()}
			reg := registry.New(testLogger())
			var rejected *registry.Provider
			for i, key := range test.keys {
				p := addProvider(reg, key, key, key, "Mac15,8", test.memory[i])
				setSerial(p, key, "Mac15,8")
				p.AccountID = test.accounts[i]
				st.sessions = append(st.sessions, fullUptimeSession(key, key, key, test.accounts[i], start, end))
				st.earnings = append(st.earnings, organicEarning(key, test.accounts[i], key, test.earned[i], start.Add(time.Minute)))
				rejected = p
			}
			if test.prior > 0 {
				if paid, err := st.inner.SettleProviderFloorDraw(context.Background(), &store.ProviderFloorDraw{ProviderKey: "historical", AccountID: "shared", EpochID: epoch, AmountMicroUSD: test.prior}); err != nil || !paid {
					t.Fatal("prior setup", err)
				}
			}
			st.check = func(plan, index, pass int) {
				if plan == 1 && index == len(test.keys)-1 && pass == 1 {
					rejected.Mu().Lock()
					rejected.Status = registry.StatusOffline
					rejected.Mu().Unlock()
				}
			}
			e := newTestEngine(st, reg, clock)
			e.cfg.PoolBudgetMicroUSD = test.budget * 8928 // fixed test epoch is January 2025
			e.cfg.WorkhorseReserveFrac, e.cfg.PerAccountCapFrac = test.reserve, test.cap
			result, err := e.SettleEpoch(context.Background(), epoch)
			if err != nil || len(st.plans) != 2 || result.TotalDrawMicroUSD != test.budget-test.prior {
				t.Fatalf("reallocation: %+v plans=%d %v", result, len(st.plans), err)
			}
			if got := rewardPlanAmounts(st.plans[0]); !reflect.DeepEqual(got, test.first) {
				t.Fatalf("test did not produce adversarial plan: %+v", got)
			}
			draws, err := st.ListFloorDrawsForEpoch(context.Background(), epoch)
			actual := make(map[string]int64)
			for _, draw := range draws {
				actual[draw.ProviderKey] = draw.AmountMicroUSD
			}
			if err != nil || !reflect.DeepEqual(actual, test.final) {
				t.Fatalf("frozen or underpaid rows: %+v %v", actual, err)
			}
			again, err := e.SettleEpoch(context.Background(), epoch)
			if err != nil || again.Settled != 0 || again.TotalDrawMicroUSD != 0 {
				t.Fatalf("repeat paid twice: %+v %v", again, err)
			}
			if sum, _ := st.SumFloorDrawsForEpoch(context.Background(), epoch); sum != test.budget {
				t.Fatalf("pool=%d, want %d", sum, test.budget)
			}
		})
	}
}

func TestRewardPlanWithoutRejectionsPreservesAllocatorOutput(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	st := &reallocatingEngineStore{engineStore: newEngineStore()}
	reg := registry.New(testLogger())
	for i, key := range []string{"a-nonworkhorse", "z-workhorse"} {
		mem := 32
		earned := int64(0)
		if i == 1 {
			mem = 64
			earned = 2016
		}
		p := addProvider(reg, key, key, key, "Mac15,8", mem)
		setSerial(p, key, "Mac15,8")
		p.AccountID = key
		st.sessions = append(st.sessions, fullUptimeSession(key, key, key, key, start, end))
		st.earnings = append(st.earnings, organicEarning(key, key, key, earned, start.Add(time.Minute)))
	}
	e := newTestEngine(st, reg, clock)
	e.cfg.PoolBudgetMicroUSD = 1000 * 8928
	e.cfg.WorkhorseReserveFrac = .5
	result, err := e.SettleEpoch(context.Background(), epoch)
	want := map[string]int64{"a-nonworkhorse": 500, "z-workhorse": 500}
	if err != nil || result.Settled != 2 || len(st.plans) != 1 || !reflect.DeepEqual(rewardPlanAmounts(st.plans[0]), want) {
		t.Fatalf("normal allocations changed: %+v %+v %v", result, st.plans, err)
	}
}
