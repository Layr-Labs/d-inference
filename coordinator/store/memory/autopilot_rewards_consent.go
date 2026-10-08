package memory

import (
	"context"
	"errors"
	"math"
	"time"
	"unicode/utf8"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

type autopilotRewardConsentHistory struct {
	accountID  string
	observedAt time.Time
	events     []autopilotRewardConsentEvent
}

type autopilotRewardConsentEvent struct {
	earningsfloor.Consent
	observedAt time.Time
}

type autopilotRewardDeclarations struct {
	firstPositive    time.Time
	firstDeclaration time.Time
	firstUnsupported time.Time
	latest           earningsfloor.Consent
}

// Declarations are journaled by authenticated session before asynchronous
// inventory binding. ErrIdentity means the declaration survived but cannot yet
// authorize an enrollment, not that the original first-opt-in instant was lost.
func (s *MemoryStore) ObserveAutopilotConsent(ctx context.Context, consent earningsfloor.Consent) (earningsfloor.Enrollment, error) {
	if err := ctx.Err(); err != nil {
		return earningsfloor.Enrollment{}, err
	}
	consent.At = consent.At.UTC().Truncate(time.Microsecond)
	if consent.SessionID == "" || consent.AccountID == "" || consent.At.IsZero() || (!consent.Supported && consent.OptedIn) ||
		len(consent.Chip) > 128 || !utf8.ValidString(consent.Chip) || consent.MemoryGB < 0 || math.IsNaN(consent.MemoryGB) || math.IsInf(consent.MemoryGB, 0) {
		return earningsfloor.Enrollment{}, earningsfloor.ErrIdentity
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if consent.At.After(s.now()) {
		return earningsfloor.Enrollment{}, errors.New("future autopilot consent")
	}
	if s.erasedAccounts[consent.AccountID] || s.erasedProviderLocked(consent.SessionID) {
		return earningsfloor.Enrollment{}, store.ErrErasureConflict
	}
	if err := s.accountAdmissionLocked(consent.AccountID); err != nil {
		return earningsfloor.Enrollment{}, err
	}
	history := s.autopilotRewardConsents[consent.SessionID]
	if history.accountID != "" && history.accountID != consent.AccountID {
		return earningsfloor.Enrollment{}, earningsfloor.ErrIdentity
	}
	for _, session := range s.history.ProviderSessions {
		if session.SessionID == consent.SessionID && session.AccountID != "" && session.AccountID != consent.AccountID {
			return earningsfloor.Enrollment{}, earningsfloor.ErrIdentity
		}
	}
	if provider := s.providerRecords[consent.SessionID]; provider != nil && provider.AccountID != "" && provider.AccountID != consent.AccountID {
		return earningsfloor.Enrollment{}, earningsfloor.ErrIdentity
	}
	var machine autopilotRewardMachine
	if inventory := s.machineInventory; inventory != nil {
		if observation, known := inventory.Sessions[consent.SessionID]; known {
			if observation.AccountID != consent.AccountID {
				return earningsfloor.Enrollment{}, earningsfloor.ErrIdentity
			}
			id := inventory.SessionMachines[consent.SessionID]
			if inventory.Machines[id].Assurance != "provisional" {
				var err error
				machine, err = s.autopilotRewardMachineLocked(id)
				if err != nil {
					return earningsfloor.Enrollment{}, err
				}
			}
		}
	}
	// Other sessions can reach storage out of receive-time order. Preserve
	// their earlier declarations; projection still selects the latest time.
	changed := consent.At.After(history.observedAt)
	if changed {
		history.accountID, history.observedAt = consent.AccountID, consent.At
		history.events = append([]autopilotRewardConsentEvent(nil), history.events...)
		last := len(history.events) - 1
		// Same-state checkpoints never cross a UTC day. Their last observation
		// remains sufficient for exact day-end ordering after identity merges.
		if last < 0 || !sameAutopilotRewardConsent(history.events[last].Consent, consent) || !floorpolicy.Day(history.events[last].At).Equal(floorpolicy.Day(consent.At)) {
			history.events = append(history.events, autopilotRewardConsentEvent{Consent: consent, observedAt: consent.At})
		} else {
			history.events[last].observedAt = consent.At
		}
	}
	if err := ctx.Err(); err != nil {
		return earningsfloor.Enrollment{}, err
	}
	// The accepted declaration is independent evidence. A later baseline
	// calculation failure must not lose the original first-opt-in instant.
	if changed {
		s.autopilotRewardConsents[consent.SessionID] = history
	}
	var enrollment earningsfloor.Enrollment
	if machine.id != "" {
		var err error
		enrollment, err = s.autopilotRewardEnrollmentLocked(ctx, machine)
		if err != nil {
			return earningsfloor.Enrollment{}, err
		}
	}
	if err := ctx.Err(); err != nil {
		return earningsfloor.Enrollment{}, err
	}
	if machine.id == "" {
		return earningsfloor.Enrollment{}, earningsfloor.ErrIdentity
	}
	if enrollment.MachineID != "" {
		s.autopilotRewardEnrollments[enrollment.MachineID] = enrollment
	}
	return projectAutopilotRewardEnrollment(enrollment, machine.id), nil
}

func sameAutopilotRewardConsent(a, b earningsfloor.Consent) bool {
	return sameAutopilotRewardState(a, b) && a.Chip == b.Chip && a.MemoryGB == b.MemoryGB
}

func sameAutopilotRewardState(a, b earningsfloor.Consent) bool {
	return a.Supported == b.Supported && a.OptedIn == b.OptedIn && a.Qualified == b.Qualified
}

func (s *MemoryStore) autopilotRewardDeclarationsLocked(machine autopilotRewardMachine) (autopilotRewardDeclarations, error) {
	var declarations autopilotRewardDeclarations
	ambiguous := false
	for session := range machine.sessions {
		history := s.autopilotRewardConsents[session]
		if len(history.events) == 0 {
			continue
		}
		if history.accountID != machine.accountID {
			return declarations, earningsfloor.ErrIdentity
		}
		last := history.events[len(history.events)-1].Consent
		last.At = history.observedAt
		if last.At.Equal(declarations.latest.At) && !sameAutopilotRewardState(last, declarations.latest) {
			ambiguous = true
		}
		if last.At.After(declarations.latest.At) {
			declarations.latest = last
			ambiguous = false
		}
		for _, event := range history.events {
			first := &declarations.firstDeclaration
			if !event.Supported {
				first = &declarations.firstUnsupported
			}
			if first.IsZero() || event.At.Before(*first) {
				*first = event.At
			}
			if event.Supported && event.OptedIn && (declarations.firstPositive.IsZero() || event.At.Before(declarations.firstPositive)) {
				declarations.firstPositive = event.At
			}
		}
	}
	if ambiguous {
		return declarations, earningsfloor.ErrIdentity
	}
	return declarations, nil
}

// This prepares an enrollment without mutating it; the caller commits after
// all validation. Original enrollment IDs never move with inventory aliases.
func (s *MemoryStore) autopilotRewardEnrollmentLocked(ctx context.Context, machine autopilotRewardMachine) (earningsfloor.Enrollment, error) {
	declarations, err := s.autopilotRewardDeclarationsLocked(machine)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	var enrollment earningsfloor.Enrollment
	for ancestor := range machine.aliases {
		candidate, exists := s.autopilotRewardEnrollments[ancestor]
		if exists && (enrollment.MachineID == "" || earlierAutopilotRewardEnrollment(candidate, enrollment)) {
			enrollment = candidate
		}
	}
	if enrollment.MachineID == "" {
		first := declarations.firstPositive
		if first.IsZero() {
			return enrollment, nil
		}
		enrollment = earningsfloor.Enrollment{MachineID: machine.id, AccountID: machine.accountID, FirstObservedAt: first, NextDay: floorpolicy.Day(first)}
		tracking := s.autopilotRewardPool.TrackingStartedAt
		if enrollment.NextDay.Before(floorpolicy.Day(tracking)) {
			enrollment.NextDay = floorpolicy.Day(tracking)
		}
		if s.autopilotRewardTrackingCompleteLocked(machine, declarations, first) {
			sum, source, evidence, err := s.autopilotRewardBaselineLocked(ctx, machine, first)
			if err != nil && !errors.Is(err, earningsfloor.ErrHistory) {
				return earningsfloor.Enrollment{}, err
			}
			if err == nil {
				floor, err := floorpolicy.DailyFloor(sum)
				if err != nil {
					return earningsfloor.Enrollment{}, err
				}
				enrollment.FirstOptInAt, enrollment.BaselineKnown = &first, true
				enrollment.SevenDayEarningsMicroUSD, enrollment.DailyFloorMicroUSD = sum, floor
				enrollment.BaselineSource = source
				enrollment.BaselineEvidence = evidence
			}
		}
	}
	enrollment.HistoryConflict = s.autopilotRewardHistoryConflictLocked(machine, declarations, enrollment)
	enrollment.OptedIn = declarations.latest.Supported && declarations.latest.OptedIn
	enrollment.ObservedAt = declarations.latest.At
	return enrollment, nil
}

func (s *MemoryStore) autopilotRewardHistoryConflictLocked(machine autopilotRewardMachine, declarations autopilotRewardDeclarations, enrollment earningsfloor.Enrollment) bool {
	if !enrollment.BaselineKnown {
		return false
	}
	if (enrollment.BaselineSource == earningsfloor.TrackedBaseline || enrollment.BaselineSource == earningsfloor.CohortBaseline) && !s.autopilotRewardTrackingCompleteLocked(machine, declarations, *enrollment.FirstOptInAt) {
		return true
	}
	if !declarations.firstPositive.IsZero() && declarations.firstPositive.Before(*enrollment.FirstOptInAt) {
		return true
	}
	for ancestor := range machine.aliases {
		prior, exists := s.autopilotRewardEnrollments[ancestor]
		if exists && !prior.BaselineKnown && prior.FirstObservedAt.Before(*enrollment.FirstOptInAt) {
			return true
		}
	}
	return false
}

// New identity evidence can invalidate automatic tracking proof, but never
// changes the frozen financial snapshot or an independently verified baseline.
func (s *MemoryStore) autopilotRewardTrackingCompleteLocked(machine autopilotRewardMachine, declarations autopilotRewardDeclarations, first time.Time) bool {
	tracking := s.autopilotRewardPool.TrackingStartedAt
	if machine.firstSeen.Before(tracking) || first.Before(tracking) || declarations.firstDeclaration.IsZero() || declarations.firstDeclaration.After(machine.firstSeen) {
		return false
	}
	if !declarations.firstUnsupported.IsZero() && !declarations.firstUnsupported.After(first) {
		return false
	}
	// An earlier positive declaration with no verified association could be
	// this machine's first session. It cannot be silently re-anchored here.
	for session, history := range s.autopilotRewardConsents {
		if history.accountID != machine.accountID || machine.sessions[session] {
			continue
		}
		id := s.machineInventory.SessionMachines[session]
		identity, bound := s.machineInventory.Machines[id]
		if bound && identity.Assurance != "provisional" && s.machineInventory.Sessions[session].AccountID == history.accountID {
			continue
		}
		for _, event := range history.events {
			if event.Supported && event.OptedIn && !event.At.After(first) {
				return false
			}
		}
	}
	return true
}

func earlierAutopilotRewardEnrollment(a, b earningsfloor.Enrollment) bool {
	if a.BaselineKnown != b.BaselineKnown {
		return a.BaselineKnown
	}
	if a.BaselineKnown && !a.FirstOptInAt.Equal(*b.FirstOptInAt) {
		return a.FirstOptInAt.Before(*b.FirstOptInAt)
	}
	if !a.FirstObservedAt.Equal(b.FirstObservedAt) {
		return a.FirstObservedAt.Before(b.FirstObservedAt)
	}
	return a.MachineID < b.MachineID
}

func projectAutopilotRewardEnrollment(enrollment earningsfloor.Enrollment, canonical string) earningsfloor.Enrollment {
	if enrollment.MachineID != "" {
		enrollment.MachineID = canonical
	}
	if enrollment.FirstOptInAt != nil {
		first := *enrollment.FirstOptInAt
		enrollment.FirstOptInAt = &first
	}
	return enrollment
}

func (s *MemoryStore) autopilotRewardConsentBeforeLocked(machine autopilotRewardMachine, end time.Time) (bool, bool, error) {
	var latest earningsfloor.Consent
	ambiguous := false
	for session := range machine.sessions {
		for _, event := range s.autopilotRewardConsents[session].events {
			if !event.observedAt.Before(end) {
				break
			}
			if event.observedAt.Equal(latest.At) && !sameAutopilotRewardState(event.Consent, latest) {
				ambiguous = true
			}
			if event.observedAt.After(latest.At) {
				latest = event.Consent
				latest.At = event.observedAt
				ambiguous = false
			}
		}
	}
	if ambiguous {
		return false, false, earningsfloor.ErrIdentity
	}
	return latest.Supported && latest.OptedIn, latest.Qualified, nil
}
