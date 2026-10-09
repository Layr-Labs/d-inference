package registry

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Routing an inference request to a verified pair.
//
// A pair is one routable unit. Its leader (rank 0) connection is the routing
// candidate: it is sent the ordinary inference_request and answers it. The
// follower connection is never a candidate. A leader is selected only while
// its exact pair is active, both key confirmations were relayed, its own
// heartbeat reports the pair model loaded, and enough of the pair's fixed
// lifetime remains for the request. While the pair exists, anything short of
// that is a capacity wait, not an error. Nothing in this file runs unless the
// operator enabled cluster pairs: with the switch off no member connection is
// ever a candidate.

// clusterPairServesOwnerAccountOnly restricts a pair to requests that are
// authenticated as the account owning both members and scoped to that
// account's own machines (self-route or prefer-owner). Every other request
// sees the pair as absent capacity.
//
// The restriction exists because the two members exchange model activations
// over a link the coordinator neither authenticates nor encrypts, and because
// the verification a consumer receives describes the leader only. Lift it only
// when both are fixed: an authenticated, encrypted data plane between the
// members, and a consumer verification snapshot that covers both members.
const clusterPairServesOwnerAccountOnly = true

// pairRequestLifetimeCap bounds how much remaining pair lifetime one request
// may demand. A request estimated to run longer is admitted in the first part
// of a pair's lifetime instead of never.
const pairRequestLifetimeCap = verifiedPairLifetimeLimit / 2

// pairRequestCancelWrite bounds one best-effort cancel write to a leader whose
// pair ended.
const pairRequestCancelWrite = 2 * time.Second

// ClusterPairRequestScope names, for listings, whose requests a pair serves.
func ClusterPairRequestScope() string {
	if clusterPairServesOwnerAccountOnly {
		return "owner_account"
	}
	return "any_account"
}

// ClusterPairLifetime is the fixed lifetime of one pair session; a cluster
// re-forms after each.
func ClusterPairLifetime() time.Duration { return verifiedPairLifetimeLimit }

// EnableClusterPairRouting is the operator's opt-in for routing requests to
// verified pairs. It is set once, before the coordinator serves traffic.
func (r *Registry) EnableClusterPairRouting() {
	r.pairRouting.Store(true)
}

// ledPairLocked returns the pair that p leads for model and that is forming,
// serving or rotating, or nil. A solo connection, the follower, a pair for
// another model and every member while routing is off have none. Neither has a
// quarantined pair whose owners must have retired: only a connected member
// that never reported cleanup still holds it, and no time ends that hold, so
// it is no longer a pair anyone waits for. Caller holds r.mu.
func (r *Registry) ledPairLocked(p *Provider, model string, now time.Time) *verifiedPairState {
	if p.executionRole != protocol.ExecutionRoleClusterMember || !r.pairRouting.Load() {
		return nil
	}
	s := r.verifiedPairs.connections[p]
	if s == nil || s.phase == VerifiedPairReleased || s.providers[0] != p || s.membership.Model != model {
		return nil
	}
	if s.phase == VerifiedPairQuarantined && !now.Before(verifiedPairOwnersRetiredBy(s)) {
		return nil
	}
	return s
}

// requestPairLocked returns the pair a request may reach through p. ownerScoped
// says the request is authenticated as p's own account and scoped to that
// account's machines; it is the caller's existing self-route decision. Caller
// holds r.mu and p.mu.
func (r *Registry) requestPairLocked(p *Provider, model string, ownerScoped bool, now time.Time) *verifiedPairState {
	s := r.ledPairLocked(p, model, now)
	if s == nil {
		return nil
	}
	if clusterPairServesOwnerAccountOnly && (!ownerScoped || s.account == "" || p.AccountID != s.account) {
		return nil
	}
	return s
}

// listedForModelLocked reports whether p may be counted as a provider of model
// in a listing or an availability answer. A solo connection always may. A
// cluster member never is by itself: its pair is counted once, through its
// leader, for the pair's model, and only where the listing's audience may be
// routed to the pair. ownerView is true for a listing scoped to p's own
// account; every other listing describes the public fleet. Caller holds r.mu
// and p.mu.
func (r *Registry) listedForModelLocked(p *Provider, model string, ownerView bool) bool {
	if p.executionRole != protocol.ExecutionRoleClusterMember {
		return true
	}
	return r.requestPairLocked(p, model, ownerView, time.Now()) != nil
}

// verifiedPairAccountLocked is the one account both members belong to, or
// empty. Caller holds both member locks.
func verifiedPairAccountLocked(members [2]*Provider) string {
	if members[0].AccountID != members[1].AccountID {
		return ""
	}
	return members[0].AccountID
}

// pairAdmittingLocked reports whether the pair may take a new request now,
// apart from the leader's own slot and capacity. Caller holds r.mu.
func pairAdmittingLocked(s *verifiedPairState, now time.Time) bool {
	return s.phase == VerifiedPairActive && s.keysRelayed && now.Before(s.membership.ExpiresAt)
}

// verifiedPairServingReady reports whether a request from the pair's account
// would be handed to its leader now: routing is on, the pair is admitting, and
// the leader is not draining and reports the pair model loaded.
func (r *Registry) verifiedPairServingReady(h *VerifiedPairHandle) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, err := r.verifiedPairHandleLocked(h)
	now := time.Now()
	if err != nil || !r.pairRouting.Load() || !pairAdmittingLocked(s, now) {
		return false
	}
	leader := s.providers[0]
	leader.mu.Lock()
	defer leader.mu.Unlock()
	if providerDrainingLocked(leader, now) || leader.BackendCapacity == nil {
		return false
	}
	for _, slot := range leader.BackendCapacity.Slots {
		if slot.Model == s.membership.Model && slotStateModelLoaded(slot.State) {
			return true
		}
	}
	return false
}

// pairCandidateGate applies the pair-only capacity gates to a leader snapshot.
// Both outcomes are transient: the request waits for this pair or the next.
func pairCandidateGate(snap *routingSnapshot, pr *PendingRequest, now time.Time) (GateReason, bool) {
	if !snap.pairAdmitting || !slotStateModelLoaded(snap.slotState) {
		return GatePairNotReady, false
	}
	if snap.pairExpiresAt.Sub(now) < pairRequestBudget(snap, pr) {
		return GatePairLifetime, false
	}
	return GateReasonCount, true
}

// pairRequestBudget is the coordinator's estimate of how long this request
// occupies the leader: its prompt at the leader's prefill rate plus its token
// allowance at the decode rate, capped at pairRequestLifetimeCap.
func pairRequestBudget(snap *routingSnapshot, pr *PendingRequest) time.Duration {
	prompt, output := max(pr.EstimatedPromptTokens, 0), pr.RequestedMaxTokens
	if output <= 0 {
		output = defaultRequestedMaxTokens
	}
	seconds := float64(prompt)/resolvePrefillTPS(snap) + float64(output)/resolveEffectiveTPS(snap)
	if !(seconds < pairRequestLifetimeCap.Seconds()) {
		return pairRequestLifetimeCap
	}
	return time.Duration(seconds * float64(time.Second))
}

// pairLeaderHoldsOnlyPairWorkLocked reports whether p is the leader of s and
// holds nothing but the pair's own work: requests reserved on this pair and at
// most one loaded slot for the pair model. It is false for the follower and
// while requests are not routed to pairs. Caller holds r.mu and p.mu.
func (r *Registry) pairLeaderHoldsOnlyPairWorkLocked(p *Provider, s *verifiedPairState) bool {
	if s.providers[0] != p || !r.pairRouting.Load() {
		return false
	}
	if p.pairModelCommandsInFlight != 0 || r.providerHasPendingLoad(p.ID) || p.BackendCapacity == nil {
		return false
	}
	for _, pr := range p.pendingReqs {
		if pr == nil || pr.pair != s {
			return false
		}
	}
	model := s.membership.Model
	if len(p.BackendCapacity.Slots) > 1 || (p.CurrentModel != "" && p.CurrentModel != model) {
		return false
	}
	for _, warm := range p.WarmModels {
		if warm != model {
			return false
		}
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model != model || !slotStateModelLoaded(slot.State) {
			return false
		}
	}
	return true
}

// failPairRequests ends every request still reserved on a pair whose admission
// closed. Each request gets the health-neutral restart terminal, which fails
// over like a graceful provider restart and strikes no health tracker, and the
// leader is then told to stop generating. The relay calls it when it cancels a
// session whose leader is still attached. It must run without registry or
// provider locks.
//
// When the leader's own connection already left the registry this does
// nothing: Disconnect fails every request on that connection itself, with the
// cause that says how the socket ended.
func (r *Registry) failPairRequests(s *verifiedPairState) {
	if !r.pairRouting.Load() {
		return
	}
	leader := s.providers[0]
	r.mu.RLock()
	connected := r.providers[leader.ID] == leader
	r.mu.RUnlock()
	if !connected {
		return
	}
	leader.mu.Lock()
	var failed []*PendingRequest
	for id, pr := range leader.pendingReqs {
		if pr != nil && pr.pair == s {
			leader.removePendingLocked(id)
			failed = append(failed, pr)
		}
	}
	if len(failed) > 0 && leader.pendingCount() == 0 && leader.Status == StatusServing {
		leader.Status = StatusOnline
	}
	leader.mu.Unlock()
	if len(failed) == 0 {
		return
	}
	for _, pr := range failed {
		r.MarkCacheAttemptTerminal(pr)
		deliverPairEnded(pr)
	}
	for _, pr := range failed {
		cancel, err := json.Marshal(protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: pr.RequestID})
		if err != nil {
			continue
		}
		ctx, done := context.WithTimeout(context.Background(), pairRequestCancelWrite)
		_ = leader.EnqueueText(ctx, cancel)
		done()
	}
	r.logger.Info("verified pair ended with requests in flight", "provider_id", leader.ID, "requests", len(failed))
}

// deliverPairEnded hands a request the coordinator's restart terminal. The
// caller took the request out of the leader's pending set, so nothing else
// writes its error channel. Only that channel is used: the leader is still
// connected and its read loop may be delivering a chunk for this request, so
// the chunk and completion channels must not be closed from here.
func deliverPairEnded(pr *PendingRequest) {
	if pr.ErrorCh == nil {
		return
	}
	defer func() { recover() }()
	pr.ErrorCh <- protocol.InferenceErrorMessage{
		Type:             protocol.TypeInferenceError,
		RequestID:        pr.RequestID,
		Error:            "provider disconnected",
		StatusCode:       502,
		ErrorReason:      disconnectFlushErrorReason(protocol.CoordinatorCauseProviderRestart),
		CoordinatorCause: protocol.CoordinatorCauseProviderRestart,
	}
	close(pr.ErrorCh)
}
