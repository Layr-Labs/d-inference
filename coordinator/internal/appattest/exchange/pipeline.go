package exchange

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/diagnostics"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type PipelineDependencies struct {
	Verification  Dependencies
	Archive       store.AppAttestArchiveStore
	Enrollments   store.AppAttestEnrollmentStore
	Provider      *registry.Provider
	Budget        *storagebudget.Budget
	Scope         *storagebudget.Scope
	Integrity     *evidence.Integrity
	Authorization *authorization.Controller
	Count         func(string, []string)
	Transition    func(Result, protocol.AppAttestShadowPayload) string
}

// Attempt is the issued challenge plus its bounded worker disposition. It does
// not contain inboxes, locks, mutable service state or archive ownership.
type Attempt struct {
	Challenge       Challenge
	ReadyContext    map[string]any
	Rejection       string
	PreviousOutcome string
}

type ReplyResult struct {
	Result
	Outcome string
}

type Pipeline struct{ deps PipelineDependencies }

func NewPipeline(deps PipelineDependencies) *Pipeline { return &Pipeline{deps: deps} }

// RetainUnsolicited keeps the active timer only if the late frame was archived.
func (p *Pipeline) RetainUnsolicited(ctx context.Context, attempt Attempt, reply protocol.AppAttestShadowPayload) (bool, ReplyResult) {
	before := p.deps.Integrity.Dropped()
	operation, cancel := context.WithTimeout(ctx, 2*time.Second)
	result := p.Handle(operation, attempt, reply)
	cancel()
	if p.deps.Integrity.Dropped() != before {
		result.Outcome = "storage_error"
		return false, result
	}
	return true, result
}

// Handle owns the archival permit through final rejection completion. Every
// admitted proof is retained before protocol, timing, or cryptographic checks.
func (p *Pipeline) Handle(ctx context.Context, attempt Attempt, reply protocol.AppAttestShadowPayload) (result ReplyResult) {
	d := p.deps
	c := attempt.Challenge
	result.Result.Next, result.Outcome = "stop", attempt.PreviousOutcome
	entryOutcome, pending := "rejected", ""
	observe := func(stage, outcome string, metadata *appattest.Key, frame protocol.AppAttestShadowPayload) {
		if stage != "archive" {
			result.Outcome = outcome
			if pending != "" {
				entryOutcome = outcome
			}
		}
		if d.Verification.Observe != nil {
			d.Verification.Observe(stage, outcome, metadata, frame)
		}
	}
	count := func(name string, tags []string) {
		if d.Count != nil {
			d.Count(name, tags)
		}
	}
	drop := func() { d.Integrity.Drop(d.Authorization, d.Provider) }
	archiveProof := reply.Proof != "" || reply.Action == "attestation" || reply.Action == "assertion" || c.Expected == "attestation" || c.Expected == "assertion"
	if archiveProof && d.Archive != nil {
		diagnostics.Derive(ctx, d.Budget, d.Archive, c.Credential, attempt.ReadyContext)
	}
	release, ok := d.Scope.Acquire()
	if !ok {
		result.Outcome = "storage_busy"
		drop()
		observe("archive", "storage_busy", nil, protocol.AppAttestShadowPayload{})
		return result
	}
	defer release()
	if archiveProof {
		if d.Archive == nil {
			drop()
			observe("archive", "unavailable", nil, protocol.AppAttestShadowPayload{})
			return result
		}
		previous := uint32(0)
		if c.Credential != nil {
			c.Binding.KeyID = &c.Credential.KeyID
			previous = c.Credential.Counter
		} else {
			c.Binding.KeyID = nil
		}
		writer := evidence.NewWriter(d.Archive, d.Enrollments, d.Provider)
		entry, err := writer.Begin(ctx, evidence.Input{Binding: c.Binding, Expected: c.Expected, PreviousCounter: previous, ReadyContext: attempt.ReadyContext}, reply)
		c.Prepared, c.EvidenceID, pending = &entry.Prepared, entry.Evidence.ID, entry.Evidence.ID
		if err != nil {
			drop()
			result.Outcome, pending = "write_failed", ""
			observe("archive", "write_failed", nil, protocol.AppAttestShadowPayload{})
			return result
		}
		count("app_attest.archive.received", nil)
		defer func() {
			if pending == "" {
				return
			}
			final, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			outcome, err := d.Archive.CompleteAppAttestEvidence(final, pending, store.AppAttestDecision{Outcome: entryOutcome, Receipt: entry.UnverifiedReceipt})
			if err != nil {
				drop()
				observe("archive", "completion_failed", nil, protocol.AppAttestShadowPayload{})
			} else {
				count("app_attest.archive.completed", []string{"outcome:" + outcome})
			}
		}()
	}
	if reply.Session != c.Binding.Session || reply.Action != c.Expected {
		observe("protocol", "unexpected_reply", nil, protocol.AppAttestShadowPayload{})
		if c.Expected == "" && reply.Session == c.Binding.Session {
			result.Result.Next = "ignore"
		}
		return result
	}
	if attempt.Rejection != "" {
		result.Outcome = attempt.Rejection
		observe("archive", attempt.Rejection, nil, protocol.AppAttestShadowPayload{})
		entryOutcome = attempt.Rejection
		return result
	}
	verify := d.Verification
	verify.Observe = observe
	commitFailed := false
	verify.Commit = func(ctx context.Context, decision store.AppAttestDecision) bool {
		if d.Archive == nil || pending == "" {
			drop()
			observe("archive", "unavailable", nil, protocol.AppAttestShadowPayload{})
			return false
		}
		outcome, err := evidence.NewCommitter(d.Archive, d.Integrity, d.Authorization, d.Provider).Complete(ctx, pending, c.Expected, decision)
		if err != nil {
			commitFailed = true
			entryOutcome, result.Outcome = "storage_error", "storage_error"
			observe("archive", "completion_failed", nil, protocol.AppAttestShadowPayload{})
			return false
		}
		pending = ""
		count("app_attest.archive.completed", []string{"outcome:" + outcome})
		if outcome != "verified" {
			observe(c.Expected, outcome, nil, protocol.AppAttestShadowPayload{})
			return false
		}
		return true
	}
	result.Result = Verify(ctx, verify, c, reply)
	if d.Transition != nil {
		outcome := d.Transition(result.Result, reply)
		// Archive diagnostics leave the worker's prior outcome unchanged.
		// A failed commit must remain retryable after applying the transition.
		if !commitFailed {
			result.Outcome = outcome
		}
	}
	return result
}
