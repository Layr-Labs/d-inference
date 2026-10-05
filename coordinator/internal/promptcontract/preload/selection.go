package preload

import (
	"slices"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

// PreloadSelectionSource projects exact verified artifacts through current
// Registry policy. It is installed once before Start and runs outside c.mu.
// Public model availability is only an advisory FIFO tie-break, not authority.
type PreloadSelectionSource func([]VerifiedPreloadArtifact, bool) ([]PreloadDemandIdentity, []string)

// PlanningState separates a completed tokenizer acknowledgement from current
// exact Registry eligibility. Neither boolean is inference authorization.
type PreloadPlanningState struct {
	Acknowledged  bool
	Participating bool
}

// Admissibility does not change already-loaded tokenizer bytes. Carrying a
// completed acknowledgement across only that drift is distinct from accepting
// an old in-flight result: the latter still requires the full key and lease.
func (k PreloadSelectionSnapshot) nativeEqual(other PreloadSelectionSnapshot) bool {
	return k.CatalogGeneration == other.CatalogGeneration && k.ChildGeneration == other.ChildGeneration &&
		k.SelectionGeneration == other.SelectionGeneration && k.Capacity == other.Capacity &&
		slices.Equal(k.Verified, other.Verified) && slices.Equal(k.Desired, other.Desired)
}

func (c *PreloadController) SetSelectionSource(source PreloadSelectionSource) bool {
	if c == nil || source == nil {
		return false
	}
	c.captureMu.Lock()
	defer c.captureMu.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.started || c.closed || c.inflight != 0 || c.selectionSource != nil {
		return false
	}
	c.selectionSource = source
	return true
}

// Caller holds captureMu until the input is applied under mu. A delayed reader
// therefore cannot overwrite a later already-observed authority snapshot.
func (c *PreloadController) selectionInput(refreshAvailability bool) (catalog.Snapshot, ChildStatus, PreloadSelectionInput) {
	provisioned, verified := c.provisioner.VerifiedPreloadArtifacts()
	child := c.supervisor.Status()
	c.mu.RLock()
	source := c.selectionSource
	sameVerified := c.selection.HoldsVerified(provisioned.Generation, verified)
	c.mu.RUnlock()
	if !sameVerified {
		c.publicAvailable = nil
	}
	var admissible []PreloadDemandIdentity
	var available []string
	if source != nil {
		admissible, available = source(verified, refreshAvailability)
	}
	if refreshAvailability {
		c.publicAvailable = nil
		for _, artifact := range verified {
			if slices.Contains(available, artifact.ModelID) {
				c.publicAvailable = append(c.publicAvailable, artifact.ModelID)
			}
		}
	}
	// Advisory IDs are always reprojected onto current V. They are not an
	// authorization cache, and request paths never run a whole-fleet scan.
	available = nil
	for _, artifact := range verified {
		if slices.Contains(c.publicAvailable, artifact.ModelID) {
			available = append(available, artifact.ModelID)
		}
	}
	c.publicAvailable = available
	childGeneration := child.ChildGeneration
	if !child.Running {
		childGeneration = 0
	}
	return provisioned, child, PreloadSelectionInput{
		CatalogGeneration: provisioned.Generation, ChildGeneration: childGeneration,
		Capacity: c.client.MaxPreloadIDs(), Verified: verified,
		Admissible: admissible, PubliclyAvailable: available,
	}
}

func (c *PreloadController) reconcileSelectionLocked(input PreloadSelectionInput) (PreloadSelectionSnapshot, bool) {
	if c.closed {
		return PreloadSelectionSnapshot{}, false
	}
	// Reconciliation neither issues nor retires a lease, so the outstanding
	// operation read here is still the policy's after it.
	before := c.selection.State()
	key, err := c.selection.Reconcile(c.policyNow(), input)
	if err != nil {
		c.invalidateLocked("invalid preload selection")
		return key, false
	}
	if !before.Key.Equal(key) {
		if !c.advanceOperationLocked() {
			return key, false
		}
		if !c.published.nativeEqual(key) {
			c.clearPublicationLocked("preload identity changed")
		}
		if c.inflight == 0 && before.InflightOperation == 0 && before.Key.nativeEqual(key) &&
			before.BatchRetryKey.Equal(before.Key) && before.BatchRetryAt > 0 && before.FailedResult {
			// A completed failed/partial native batch has not changed. Rekey
			// its original deadline without resetting it or withdrawing A's
			// completed acknowledgement. Real V/D/child/capacity changes still
			// bypass the old batch delay; live full-K leases stay invalidated.
			c.selection.CarryBatchRetry(before.BatchRetryAt)
			c.retryIdentity = key
		} else {
			c.resetRetryLocked()
		}
	}
	return key, true
}

// NoteDemand is called only by the authenticated, final-resolved text path.
// Caller identities are checked against a fresh coherent verified snapshot and
// Registry projection before a detached exact tuple is retained. No body,
// account, request, nonce or provider value is accepted by this interface.
func (c *PreloadController) NoteDemand(identity PreloadDemandIdentity) bool {
	if c == nil {
		return false
	}
	c.captureMu.Lock()
	defer c.captureMu.Unlock()
	_, _, input := c.selectionInput(false)
	c.mu.Lock()
	defer c.mu.Unlock()
	key, valid := c.reconcileSelectionLocked(input)
	if !valid {
		return false
	}
	if c.selectionSource != nil && slices.Contains(key.Admissible, identity) {
		return c.selection.NoteDemand(c.policyNow(), identity)
	}
	return false
}

// ReadyFor retains its standalone D64 meaning: a completed, current native
// tokenizer acknowledgement. Actual API planning uses PlanningState plus the
// authoritative Registry gate; missing selection callbacks grant no authority.
func (c *PreloadController) ReadyFor(promptContractID string) bool {
	if c == nil || !sidecar.ValidHash(promptContractID) {
		return false
	}
	c.captureMu.Lock()
	defer c.captureMu.Unlock()
	_, child, input := c.selectionInput(false)
	c.mu.Lock()
	defer c.mu.Unlock()
	key, valid := c.reconcileSelectionLocked(input)
	return valid && c.nativeAcknowledgedLocked(promptContractID, key, child)
}

func (c *PreloadController) PlanningState(identity PreloadDemandIdentity) PreloadPlanningState {
	if c == nil {
		return PreloadPlanningState{}
	}
	c.captureMu.Lock()
	defer c.captureMu.Unlock()
	_, child, input := c.selectionInput(false)
	c.mu.Lock()
	defer c.mu.Unlock()
	key, valid := c.reconcileSelectionLocked(input)
	if !valid || !slices.Contains(key.Verified, identity) {
		return PreloadPlanningState{}
	}
	acknowledged := c.nativeAcknowledgedLocked(identity.PromptContractID, key, child)
	return PreloadPlanningState{Acknowledged: acknowledged,
		Participating: acknowledged && c.selectionSource != nil && slices.Contains(key.Admissible, identity)}
}

func (c *PreloadController) nativeAcknowledgedLocked(id string, key PreloadSelectionSnapshot, child ChildStatus) bool {
	_, included := c.contracts[id]
	return !c.closed && c.inflight == 0 && c.status.Ready && included && c.published.nativeEqual(key) &&
		child.Running && child.Ready && key.ChildGeneration != 0 && len(key.Desired) > 0 &&
		len(key.Desired) <= key.Capacity && slices.Contains(key.Desired, id)
}

func preloadUnavailableReason(provisioned catalog.Snapshot, child ChildStatus, selectionReason string) string {
	if provisioned.Generation == 0 {
		return "awaiting model catalog"
	}
	if !child.Running || child.ChildGeneration == 0 {
		return "awaiting prompt sidecar"
	}
	if selectionReason != "" {
		return selectionReason
	}
	if provisioned.Counts.Pending != 0 {
		return "awaiting prompt artifacts"
	}
	if provisioned.Counts.Failed != 0 {
		return "prompt artifact provisioning failed"
	}
	return "no verified prompt contracts"
}
