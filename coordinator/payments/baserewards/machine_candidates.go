package baserewards

import (
	"context"
	"slices"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/hardware"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type machineRewardGroup struct {
	candidate
	model   string
	invalid bool
}

// buildCandidates uses one floor identity per verified canonical machine while
// retaining original encryption keys for accounting. Legacy providers without
// inventory retain their existing key; App Attest providers fail closed without
// a matching durable binding. App Attest does not certify physical uniqueness.
func (e *Engine) buildCandidates(ctx context.Context, start, end time.Time) ([]candidate, error) {
	grace := time.Duration(e.cfg.GraceSeconds) * time.Second
	sessions, err := e.store.ListProviderSessionsOverlapping(ctx, start, end, grace)
	if err != nil {
		return nil, err
	}
	live := e.reg.ListProviders()
	bindings, err := e.machineRewardBindings(ctx, sessions, live)
	if err != nil {
		return nil, err
	}
	accountByKey := latestAccountByProviderKey(sessions)
	groups := make(map[string]*machineRewardGroup)
	for _, p := range live {
		if !rewardSnapshotEligible(p) {
			continue
		}
		mem, known := rewardMemoryGB(p)
		if !known {
			continue
		}
		account := p.AccountID
		if account == "" && !p.AppAttestAuthorized {
			account = accountByKey[p.ProviderKey]
		}
		if account == "" {
			continue
		}
		binding, bound := bindings[p.ID]
		bound = bound && binding.AccountID == account && (p.MachineID == "" && !p.AppAttestAuthorized || slices.Contains(binding.MachineAliases, p.MachineID))
		if p.AppAttestAuthorized && (!bound || p.MachineID == "") {
			continue
		}
		key, machine := p.ProviderKey, ""
		if bound {
			machine, key = binding.MachineID, store.MachineFloorKey(binding.MachineID)
		}
		g := groups[key]
		if g == nil {
			g = &machineRewardGroup{candidate: candidate{c: Candidate{ProviderKey: key, AccountID: account, MemGB: mem}, machineID: machine}, model: p.HardwareModel}
			groups[key] = g
		}
		// Concurrent credentials cannot manufacture two floors or select the
		// largest inconsistent memory claim. Ownership/model ambiguity is unpaid.
		g.invalid = g.invalid || g.c.AccountID != account || g.model != p.HardwareModel
		g.c.MemGB = min(g.c.MemGB, mem)
		g.live = append(g.live, p)
		g.previousKeys = append(g.previousKeys, p.ProviderKey)
		if bound {
			g.machineAliases = append(g.machineAliases, binding.MachineAliases...)
		}
	}
	// Fold overlapping/reconnected sessions onto their verified machine before
	// the existing interval union. Never add another account's uptime or earnings.
	normalized := make([]store.ProviderSession, 0, len(sessions))
	for _, session := range sessions {
		key := session.ProviderKey
		if b, ok := bindings[session.SessionID]; ok && b.AccountID == session.AccountID {
			if g := groups[store.MachineFloorKey(b.MachineID)]; g != nil && g.c.AccountID == session.AccountID {
				key = g.c.ProviderKey
				g.previousKeys = append(g.previousKeys, session.ProviderKey)
				g.machineAliases = append(g.machineAliases, b.MachineAliases...)
			}
		}
		if g := groups[key]; g == nil || g.c.AccountID != session.AccountID {
			continue
		}
		copy := session
		copy.ProviderKey = key
		normalized = append(normalized, copy)
	}
	uptime := e.uptimeByProviderKey(normalized, start, end)
	result := make([]candidate, 0, len(groups))
	for _, g := range groups {
		if g.invalid || uptime[g.c.ProviderKey] < e.cfg.MinUptimeFrac {
			continue
		}
		g.previousKeys = compactRewardKeys(g.previousKeys)
		g.machineAliases = compactRewardKeys(g.machineAliases)
		if g.machineID == "" {
			g.c.Earned, err = e.store.SumProviderEarningsByKey(ctx, g.c.ProviderKey, start, end)
		} else {
			st, _ := store.As[store.MachineRewardStore](e.store)
			g.c.Earned, err = st.SumProviderEarningsByKeysForAccount(ctx, g.c.AccountID, g.previousKeys, start, end)
		}
		if err != nil {
			return nil, err
		}
		g.uptimeFrac = uptime[g.c.ProviderKey]
		g.c.Floor = PeriodFloor(g.c.MemGB, g.uptimeFrac, start, end)
		g.c.Draw = Draw(g.c.Floor, g.c.Earned, e.cfg.ReductionK)
		result = append(result, g.candidate)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].c.ProviderKey < result[j].c.ProviderKey })
	return result, nil
}

func (e *Engine) machineRewardBindings(ctx context.Context, sessions []store.ProviderSession, live []registry.ProviderSnapshot) (map[string]store.MachineRewardBinding, error) {
	bindings := make(map[string]store.MachineRewardBinding)
	st, ok := store.As[store.MachineRewardStore](e.store)
	if !ok {
		return bindings, nil
	}
	ids := make([]string, 0, len(sessions)+len(live))
	for _, session := range sessions {
		ids = append(ids, session.SessionID)
	}
	for _, p := range live {
		ids = append(ids, p.ID)
	}
	ids = compactRewardKeys(ids)
	for len(ids) > 0 {
		n := min(len(ids), store.MachineRewardBatchLimit)
		batch, err := st.GetMachineRewardBindings(ctx, ids[:n])
		if err != nil {
			return nil, err
		}
		for id, binding := range batch {
			bindings[id] = binding
		}
		ids = ids[n:]
	}
	// A merge between batches can yield both an old and new canonical ID.
	// Follow only non-self aliases so input order cannot split the machine.
	forward := make(map[string]string)
	for _, b := range bindings {
		for _, id := range b.MachineAliases {
			if id != b.MachineID {
				forward[id] = b.MachineID
			}
		}
	}
	for id, b := range bindings {
		for n := 0; n < 100 && forward[b.MachineID] != ""; n++ {
			b.MachineID = forward[b.MachineID]
		}
		b.MachineAliases = compactRewardKeys(append(b.MachineAliases, b.MachineID))
		bindings[id] = b
	}
	return bindings, nil
}

func rewardSnapshotEligible(p registry.ProviderSnapshot) bool {
	return p.ServingAuthorized && (p.AppAttestAuthorized || p.Attested) && p.Online && p.ModelLoaded && p.ProviderKey != "" &&
		p.MemoryPressure < 0.8 && p.ThermalState != "critical"
}

func rewardMemoryGB(p registry.ProviderSnapshot) (int, bool) {
	capGB, known := hardware.ModelMaxMemoryGB(p.HardwareModel)
	if !known || p.MemoryGB <= 0 {
		return 0, false
	}
	if capGB > 0 {
		return min(p.MemoryGB, capGB), true
	}
	return p.MemoryGB, true
}

func compactRewardKeys(keys []string) []string {
	slices.Sort(keys)
	keys = slices.Compact(keys)
	if len(keys) > 0 && keys[0] == "" {
		keys = keys[1:]
	}
	return keys
}

func candidatePreviouslySettled(c candidate, settled map[string]bool) bool {
	if settled[c.c.ProviderKey] {
		return true
	}
	for _, key := range c.previousKeys {
		if settled[key] {
			return true
		}
	}
	for _, machine := range c.machineAliases {
		if settled[store.MachineFloorKey(machine)] {
			return true
		}
	}
	return false
}

func (e *Engine) eligibleCandidateSession(c candidate) (string, bool) {
	for _, original := range c.live {
		p, ok := e.reg.GetProviderRewardSnapshot(original.ID)
		if !ok || !rewardSnapshotEligible(p) || p.ProviderKey != original.ProviderKey || p.AccountID != original.AccountID || p.MachineID != original.MachineID || p.HardwareModel != original.HardwareModel {
			continue
		}
		mem, known := rewardMemoryGB(p)
		if known && mem >= c.c.MemGB {
			return p.ID, true
		}
	}
	return "", false
}
