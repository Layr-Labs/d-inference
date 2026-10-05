package preload

import (
	"errors"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

const (
	preloadActiveSetMaxTuples = 128
	preloadDemandExpiry       = 5 * time.Minute
	preloadMinimumResidence   = 30 * time.Second
	// PreloadReplacementInterval is the least time between two ordinary
	// replacements of a resident member by a waiting one.
	PreloadReplacementInterval = 30 * time.Second
)

var (
	errPreloadSelectionInput = errors.New("invalid preload active-set input")
	errPreloadSelectionClock = errors.New("preload active-set clock moved backwards")
	errPreloadSelectionLimit = errors.New("preload active-set generation exhausted")
)

// The catalog owns the verified artifact identity it hands off.
type VerifiedPreloadArtifact = catalog.VerifiedPreloadArtifact

type PreloadDemandIdentity = VerifiedPreloadArtifact

// Only acknowledged successes from the existing controller may seed a new
// policy. They seed desired residency, never publication under a new key.
type PreloadPublishedArtifacts struct {
	CatalogGeneration uint64
	ChildGeneration   uint64
	Successful        []VerifiedPreloadArtifact
}

type PreloadSelectionInput struct {
	CatalogGeneration uint64
	ChildGeneration   uint64
	Capacity          int // Actual configured Client/Supervisor capacity, not a new cap.
	Verified          []VerifiedPreloadArtifact
	Admissible        []PreloadDemandIdentity // Exact current Registry/allowlist intersection.
	PubliclyAvailable []string                // Advisory model IDs, projected onto Verified.
	Published         *PreloadPublishedArtifacts
}

// K binds full V and admissibility as well as exact desired D. Public availability
// and demand timestamps are deliberately absent: neither alone requests reload.
type PreloadSelectionSnapshot struct {
	CatalogGeneration   uint64
	ChildGeneration     uint64
	SelectionGeneration uint64
	Capacity            int
	Verified            []VerifiedPreloadArtifact
	Admissible          []PreloadDemandIdentity
	Desired             []string
}

// Equal compares the full key, including admissibility.
func (k PreloadSelectionSnapshot) Equal(other PreloadSelectionSnapshot) bool {
	return k.CatalogGeneration == other.CatalogGeneration && k.ChildGeneration == other.ChildGeneration &&
		k.SelectionGeneration == other.SelectionGeneration && k.Capacity == other.Capacity &&
		slices.Equal(k.Verified, other.Verified) && slices.Equal(k.Admissible, other.Admissible) &&
		slices.Equal(k.Desired, other.Desired)
}

func (k PreloadSelectionSnapshot) detached() PreloadSelectionSnapshot {
	k.Verified = slices.Clone(k.Verified)
	k.Admissible = slices.Clone(k.Admissible)
	k.Desired = slices.Clone(k.Desired)
	return k
}

// PreloadSelectionLease binds one preload attempt to the exact key it was
// issued under. Its holder returns it unchanged to CompleteAttempt or
// RetireConflict; a different operation or key is refused.
type PreloadSelectionLease struct {
	Operation uint64
	Key       PreloadSelectionSnapshot
}

type preloadDemand struct {
	last, waitingSince time.Duration
	waiting, requeued  bool
}

type preloadSelectedMember struct {
	admittedAt, attemptedAt time.Duration
	admitted, retained      bool
	failed                  bool
}

// PreloadActiveSet is the bounded preload selection policy.
// Caller serializes this pure policy. No IO, goroutines, callbacks, wall clock,
// auth/account/request/prompt state or readiness authority lives here. Ticks are
// nonnegative monotonic durations from one controller-local origin.
type PreloadActiveSet struct {
	key                 PreloadSelectionSnapshot
	demand              map[PreloadDemandIdentity]preloadDemand
	members             map[string]preloadSelectedMember
	retryAt             map[string]time.Duration
	batchRetryKey       PreloadSelectionSnapshot
	batchRetryAt        time.Duration
	available           map[string]bool
	successful          []string
	lastTick            time.Duration
	lastReplacement     time.Duration
	replaced            bool
	initialized         bool
	valid, closed       bool
	needsLoad           bool
	failedResult        bool
	operation           uint64
	inflight            *PreloadSelectionLease
	inflightInvalidated bool
}

func NewPreloadActiveSet() *PreloadActiveSet {
	return &PreloadActiveSet{}
}

// Snapshot is the current exact key, detached from the policy.
func (p *PreloadActiveSet) Snapshot() PreloadSelectionSnapshot { return p.key.detached() }

// Successes are the acknowledged members of the current key.
func (p *PreloadActiveSet) Successes() []string { return slices.Clone(p.successful) }

// Reason is the bounded status of a current key that is not fully loaded.
func (p *PreloadActiveSet) Reason() string {
	if p.failedResult {
		return "preload_failed"
	}
	if len(preloadContracts(p.key.Verified)) > p.key.Capacity && len(p.key.Desired) < len(preloadContracts(p.key.Verified)) {
		return "capacity_deferred"
	}
	return ""
}

func (p *PreloadActiveSet) acceptTick(now time.Duration) bool {
	if now < 0 || now < p.lastTick || p.closed {
		return false
	}
	p.lastTick = now
	return true
}

// Invalid authoritative input immediately closes this policy, but keeps an
// outstanding lease until its real completion so no replacement IO overlaps it.
func (p *PreloadActiveSet) Invalidate() {
	if p.inflight != nil {
		p.inflightInvalidated = true
	}
	p.batchRetryKey, p.batchRetryAt = PreloadSelectionSnapshot{}, 0
	p.valid, p.needsLoad, p.failedResult = false, false, false
	p.successful, p.demand, p.members, p.retryAt, p.available = nil, nil, nil, nil, nil
	p.key.CatalogGeneration, p.key.ChildGeneration, p.key.Capacity = 0, 0, 0
	p.key.Verified, p.key.Admissible = nil, nil
	p.setDesired(nil)
}

func (p *PreloadActiveSet) setDesired(desired []string) {
	sort.Strings(desired)
	if slices.Equal(p.key.Desired, desired) {
		return
	}
	if p.key.SelectionGeneration == ^uint64(0) {
		p.closed, p.valid = true, false
		p.key.Desired, p.successful = nil, nil
		return
	}
	p.key.SelectionGeneration++
	p.key.Desired = desired
	for id := range p.members {
		if !slices.Contains(desired, id) {
			delete(p.members, id)
			p.markWaiting(id, p.lastTick, false)
		}
	}
	for _, id := range desired {
		if _, ok := p.members[id]; !ok {
			p.members[id] = preloadSelectedMember{}
		}
	}
}

// Reconcile applies one authoritative input and returns the resulting key.
func (p *PreloadActiveSet) Reconcile(now time.Duration, input PreloadSelectionInput) (PreloadSelectionSnapshot, error) {
	if !p.acceptTick(now) {
		p.Invalidate()
		return p.Snapshot(), errPreloadSelectionClock
	}
	verified, admissible, err := validatePreloadSelection(input)
	if err != nil {
		p.Invalidate()
		return p.Snapshot(), err
	}
	before := p.Snapshot()
	catalogChanged := input.CatalogGeneration != p.key.CatalogGeneration
	childChanged := input.ChildGeneration != p.key.ChildGeneration
	if catalogChanged || p.demand == nil {
		p.demand, p.members, p.retryAt = make(map[PreloadDemandIdentity]preloadDemand), make(map[string]preloadSelectedMember), make(map[string]time.Duration)
	}
	p.key.CatalogGeneration, p.key.ChildGeneration, p.key.Capacity = input.CatalogGeneration, input.ChildGeneration, input.Capacity
	p.key.Verified, p.key.Admissible = verified, admissible
	p.valid = true
	p.available = make(map[string]bool, len(input.PubliclyAvailable))
	for _, artifact := range admissible {
		if slices.Contains(input.PubliclyAvailable, artifact.ModelID) {
			p.available[artifact.PromptContractID] = true
		}
	}
	p.expireDemand(now)
	for identity := range p.demand {
		if !slices.Contains(admissible, identity) {
			delete(p.demand, identity)
		}
	}
	if childChanged {
		p.retryAt = make(map[string]time.Duration)
		for id, member := range p.members {
			member.admitted, member.failed = false, false
			p.members[id] = member
		}
	}
	all, allowed := preloadContracts(verified), preloadContracts(admissible)
	for id := range p.retryAt {
		if !slices.Contains(allowed, id) {
			delete(p.retryAt, id)
		}
	}
	var desired []string
	if len(all) <= input.Capacity {
		desired = all // Preserve D64 full-V behavior, not a pruned catalog.
	} else {
		for _, id := range before.Desired {
			member, exists := p.members[id]
			if exists && slices.Contains(allowed, id) && (member.retained || p.hasDemand(id)) {
				desired = append(desired, id)
			}
		}
		if !p.initialized && input.ChildGeneration != 0 && input.Published != nil && input.Published.CatalogGeneration == input.CatalogGeneration && input.Published.ChildGeneration == input.ChildGeneration {
			for _, artifact := range input.Published.Successful {
				if index := slices.Index(admissible, artifact); index >= 0 && !slices.Contains(desired, artifact.PromptContractID) {
					id := admissible[index].PromptContractID
					desired = append(desired, id)
					p.members[id] = preloadSelectedMember{admittedAt: now, admitted: true, retained: true}
				}
			}
		}
		// Capacity reduction is a safety closure, not ordinary timed rotation.
		for len(desired) > input.Capacity {
			desired = removePreloadContract(desired, p.oldestMember(desired, now, true))
		}
		waiters := p.waiters(desired, now)
		for len(desired) < input.Capacity && len(waiters) > 0 {
			desired = append(desired, waiters[0].id)
			waiters = waiters[1:]
		}
		if len(waiters) > 0 && len(desired) == input.Capacity && (!p.replaced || now-p.lastReplacement >= PreloadReplacementInterval) {
			if victim := p.oldestMember(desired, now, false); victim != "" {
				desired = append(removePreloadContract(desired, victim), waiters[0].id)
				p.lastReplacement, p.replaced = now, true
			}
		}
	}
	p.initialized = true
	p.setDesired(desired)
	if p.closed {
		return p.Snapshot(), errPreloadSelectionLimit
	}
	if !before.Equal(p.key) {
		// A new exact requested set must not inherit the old batch's retry
		// delay. Per-contract overflow waiter eligibility remains independent.
		p.batchRetryKey, p.batchRetryAt = PreloadSelectionSnapshot{}, 0
		if p.inflight != nil {
			// Keep the operation until its real callback, but an intervening
			// safety/key change cannot be undone by a later key-equal ABA.
			p.inflightInvalidated = true
		}
		p.successful, p.failedResult = nil, false
		p.needsLoad = len(p.key.Desired) > 0
	}
	return p.Snapshot(), nil
}

// Caller has already authenticated and passed final-resolved text/preflight and
// exact Registry identity/allowlist checks. No request/auth value is accepted.
func (p *PreloadActiveSet) NoteDemand(now time.Duration, identity PreloadDemandIdentity) bool {
	if !p.valid {
		return false
	}
	index := slices.Index(p.key.Admissible, identity)
	if index < 0 || !p.acceptTick(now) {
		return false
	}
	identity = p.key.Admissible[index] // Retain owned canonical strings, not caller backing storage.
	p.expireDemand(now)
	demand, exists := p.demand[identity]
	if !exists {
		member := p.members[identity.PromptContractID]
		requeued := now < p.retryAt[identity.PromptContractID]
		demand = preloadDemand{waitingSince: now, waiting: !member.admitted, requeued: requeued}
	}
	demand.last = now
	p.demand[identity] = demand
	return true
}

func (p *PreloadActiveSet) expireDemand(now time.Duration) {
	for identity, demand := range p.demand {
		if now-demand.last >= preloadDemandExpiry {
			delete(p.demand, identity)
		}
	}
}

func (p *PreloadActiveSet) hasDemand(id string) bool {
	for identity := range p.demand {
		if identity.PromptContractID == id {
			return true
		}
	}
	return false
}

func (p *PreloadActiveSet) markWaiting(id string, now time.Duration, failed bool) {
	for identity, demand := range p.demand {
		if identity.PromptContractID == id && (!demand.waiting || failed) {
			demand.waiting, demand.waitingSince, demand.requeued = true, now, failed
			p.demand[identity] = demand
		}
	}
}

type preloadWaiter struct {
	id        string
	since     time.Duration
	requeued  bool
	available bool
}

func (p *PreloadActiveSet) waiters(desired []string, now time.Duration) []preloadWaiter {
	byContract := make(map[string]preloadWaiter)
	for identity, demand := range p.demand {
		id := identity.PromptContractID
		if slices.Contains(desired, id) || now < p.retryAt[id] || !demand.waiting {
			continue
		}
		candidate := preloadWaiter{id, demand.waitingSince, demand.requeued, p.available[id]}
		previous, exists := byContract[id]
		if !exists || preloadWaiterLess(candidate, previous) {
			byContract[id] = candidate
		}
	}
	result := make([]preloadWaiter, 0, len(byContract))
	for _, waiter := range byContract {
		result = append(result, waiter)
	}
	sort.Slice(result, func(i, j int) bool { return preloadWaiterLess(result[i], result[j]) })
	return result
}

func preloadWaiterLess(a, b preloadWaiter) bool {
	if a.since != b.since {
		return a.since < b.since
	}
	// Append a failed attempted lease behind already-waiting identities even
	// when a deterministic clock has not advanced. Ordinary equal-age demand
	// still uses only public availability and contract-byte order as tie-breaks.
	if a.requeued != b.requeued {
		return !a.requeued
	}
	if a.available != b.available {
		return a.available
	}
	return a.id < b.id
}

func (p *PreloadActiveSet) oldestMember(ids []string, now time.Duration, safety bool) string {
	var chosen string
	var oldest time.Duration
	var failed bool
	for _, id := range ids {
		member, exists := p.members[id]
		if !safety && (!exists || (!member.failed && (!member.admitted || now-member.admittedAt < preloadMinimumResidence))) {
			continue
		}
		age := member.admittedAt
		if member.failed {
			age = member.attemptedAt
		}
		if chosen == "" || (member.failed && !failed) || (member.failed == failed && (age < oldest || (age == oldest && id < chosen))) {
			chosen, oldest, failed = id, age, member.failed
		}
	}
	return chosen
}

// BeginAttempt leases the current key for one preload when a load is due and
// no other attempt is outstanding.
func (p *PreloadActiveSet) BeginAttempt(now time.Duration) (PreloadSelectionLease, bool) {
	if !p.acceptTick(now) || !p.valid || p.inflight != nil || !p.needsLoad || p.key.ChildGeneration == 0 || len(p.key.Desired) == 0 {
		return PreloadSelectionLease{}, false
	}
	if p.key.Equal(p.batchRetryKey) && now < p.batchRetryAt {
		return PreloadSelectionLease{}, false
	}
	if p.operation == ^uint64(0) {
		p.closed = true
		p.Invalidate()
		return PreloadSelectionLease{}, false
	}
	p.operation++
	p.inflightInvalidated = false
	p.inflight = &PreloadSelectionLease{Operation: p.operation, Key: p.Snapshot()}
	p.successful = nil
	return PreloadSelectionLease{Operation: p.operation, Key: p.Snapshot()}, true
}

// Successful IDs must already come from strict Client report validation and,
// for partial reports, fresh Client.Ready. This method cannot establish either.
// Every omitted member failed/has unknown completion; no prior S is restored.
func (p *PreloadActiveSet) CompleteAttempt(now time.Duration, lease PreloadSelectionLease, successful []string, failureBackoff time.Duration) bool {
	if !p.acceptTick(now) || p.inflight == nil || lease.Operation != p.inflight.Operation || !lease.Key.Equal(p.inflight.Key) {
		return false
	}
	invalidated := p.inflightInvalidated
	p.inflight = nil
	p.inflightInvalidated = false
	if invalidated || !p.valid || !lease.Key.Equal(p.key) {
		return false
	}
	seen := make(map[string]bool, len(p.key.Desired))
	valid := len(successful) <= len(p.key.Desired)
	if valid {
		for _, id := range successful {
			if !sidecar.ValidHash(id) || seen[id] || !slices.Contains(p.key.Desired, id) {
				valid = false
				break
			}
			seen[id] = true
		}
	}
	if !valid {
		seen = map[string]bool{}
	}
	failed := len(seen) != len(p.key.Desired)
	if failed && (failureBackoff <= 0 || failureBackoff > time.Duration(1<<63-1)-now) {
		p.Invalidate()
		return false
	}
	p.batchRetryKey, p.batchRetryAt = PreloadSelectionSnapshot{}, 0
	if failed {
		p.batchRetryKey, p.batchRetryAt = p.Snapshot(), now+failureBackoff
	}
	p.successful = nil
	for _, id := range p.key.Desired {
		member := p.members[id]
		if seen[id] {
			if !member.admitted {
				member.admittedAt = now
			}
			member.admitted, member.retained, member.failed = true, true, false
			delete(p.retryAt, id)
			p.successful = append(p.successful, id)
			for identity, demand := range p.demand {
				if identity.PromptContractID == id {
					demand.waiting, demand.requeued = false, false
					p.demand[identity] = demand
				}
			}
		} else {
			member.admitted, member.retained, member.failed, member.attemptedAt = false, false, true, now
			p.retryAt[id] = now + failureBackoff
			p.markWaiting(id, now, true)
		}
		p.members[id] = member
	}
	p.needsLoad, p.failedResult = failed, failed
	return valid
}

func validatePreloadSelection(input PreloadSelectionInput) ([]VerifiedPreloadArtifact, []PreloadDemandIdentity, error) {
	if input.CatalogGeneration == 0 || input.Capacity <= 0 || len(input.Verified) > preloadActiveSetMaxTuples || len(input.Admissible) > preloadActiveSetMaxTuples || len(input.PubliclyAvailable) > preloadActiveSetMaxTuples {
		return nil, nil, errPreloadSelectionInput
	}
	verified, admissible := make([]VerifiedPreloadArtifact, 0, len(input.Verified)), make([]PreloadDemandIdentity, 0, len(input.Admissible))
	models, tuples := make(map[string]bool), make(map[VerifiedPreloadArtifact]bool)
	for _, artifact := range input.Verified {
		if !validPreloadArtifact(artifact, input.CatalogGeneration) || models[artifact.ModelID] {
			return nil, nil, errPreloadSelectionInput
		}
		artifact = clonePreloadArtifact(artifact)
		models[artifact.ModelID], tuples[artifact] = true, true
		verified = append(verified, artifact)
	}
	seen := make(map[PreloadDemandIdentity]bool)
	for _, identity := range input.Admissible {
		if !validPreloadArtifact(identity, input.CatalogGeneration) || !tuples[identity] || seen[identity] {
			return nil, nil, errPreloadSelectionInput
		}
		identity = clonePreloadArtifact(identity)
		seen[identity] = true
		admissible = append(admissible, identity)
	}
	for _, model := range input.PubliclyAvailable {
		if !validPreloadModel(model) || !models[model] {
			return nil, nil, errPreloadSelectionInput
		}
	}
	if input.Published != nil {
		if len(input.Published.Successful) > preloadActiveSetMaxTuples || (len(input.Published.Successful) > 0 && input.Published.ChildGeneration == 0) {
			return nil, nil, errPreloadSelectionInput
		}
		published := make(map[VerifiedPreloadArtifact]bool)
		for _, artifact := range input.Published.Successful {
			if !validPreloadArtifact(artifact, input.Published.CatalogGeneration) || published[artifact] {
				return nil, nil, errPreloadSelectionInput
			}
			published[artifact] = true
		}
	}
	sort.Slice(verified, func(i, j int) bool { return verified[i].ModelID < verified[j].ModelID })
	sort.Slice(admissible, func(i, j int) bool { return admissible[i].ModelID < admissible[j].ModelID })
	return verified, admissible, nil
}

func validPreloadArtifact(artifact VerifiedPreloadArtifact, generation uint64) bool {
	// Mirror the existing exact Registry artifact syntax, not a new model family
	// or provider-availability restriction. This also bounds retained model bytes.
	return generation != 0 && artifact.CatalogGeneration == generation && validPreloadModel(artifact.ModelID) &&
		sidecar.ValidHash(artifact.ModelAggregateSHA256) && sidecar.ValidHash(artifact.PromptContractID)
}

func validPreloadModel(model string) bool {
	return model != "" && len(model) <= 512 && strings.TrimSpace(model) == model && !strings.ContainsAny(model, "\x00\r\n\t*")
}

func clonePreloadArtifact(artifact VerifiedPreloadArtifact) VerifiedPreloadArtifact {
	artifact.ModelID = strings.Clone(artifact.ModelID)
	artifact.ModelAggregateSHA256 = strings.Clone(artifact.ModelAggregateSHA256)
	artifact.PromptContractID = strings.Clone(artifact.PromptContractID)
	return artifact
}

func preloadContracts(artifacts []VerifiedPreloadArtifact) []string {
	seen := make(map[string]bool, len(artifacts))
	for _, artifact := range artifacts {
		seen[artifact.PromptContractID] = true
	}
	ids := make([]string, 0, len(seen))
	for id := range seen {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func removePreloadContract(ids []string, target string) []string {
	result := make([]string, 0, len(ids))
	for _, id := range ids {
		if id != target {
			result = append(result, id)
		}
	}
	return result
}
