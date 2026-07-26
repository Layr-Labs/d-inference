package store

import (
	"context"
	"errors"
	"sync"
	"testing"
)

func setupSettlementRace(t *testing.T, backend string, st Store, id string) (*settlementContract, *RequestSettlement, RequestAttempt, RequestAttempt) {
	t.Helper()
	c := newSettlementContract(t, backend, st)
	c.seed(5_000)
	request := c.beginRequest(c.request(id, 500), false, nil)
	primary := c.attempt(request.ClientRequestID, id+"-primary", id+"-provider-primary", "primary", 0, 0)
	backup := c.attempt(request.ClientRequestID, id+"-backup", id+"-provider-backup", "backup", 0, 0)
	c.beginAttempt(primary, nil)
	c.beginAttempt(backup, nil)
	return c, request, primary, backup
}

func claimContractTerminal(t *testing.T, st Store, terminal AttemptTerminal, empty *WinnerSelection) (*AttemptTerminal, bool, error) {
	t.Helper()
	return st.ClaimAttemptTerminal(context.Background(), AttemptTerminalClaim{Terminal: terminal, EmptyWinner: empty})
}

func cancelledContractTerminal(c *settlementContract, requestID string, attempt RequestAttempt, ingress uint64) AttemptTerminal {
	terminal := c.terminal(requestID, attempt.ProviderRequestID, ingress, "cancelled", 0)
	terminal.Cause = attempt.CancelReason
	terminal.Source = "coordinator_policy"
	terminal.RequestFenceVersion = attempt.FenceVersion
	terminal.RequestFenceSequence = attempt.FenceSequence
	terminal.CancelReason = attempt.CancelReason
	return terminal
}

func TestSettlementStoreAcceptanceDoesNotSelectWinner(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, primary, backup := setupSettlementRace(t, backend, st, "acceptance")
			if err := st.AdvanceAttemptAdmission(context.Background(), request.ClientRequestID, primary.ProviderRequestID, "accepted"); err != nil {
				t.Fatalf("accept primary: %v", err)
			}
			if err := st.AdvanceAttemptAdmission(context.Background(), request.ClientRequestID, backup.ProviderRequestID, "running"); err != nil {
				t.Fatalf("run backup: %v", err)
			}
			stored, err := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			if err != nil || stored.WinnerAttemptID != "" {
				t.Fatalf("acceptance selected winner: %#v, %v", stored, err)
			}
			for _, attemptID := range []string{primary.ProviderRequestID, backup.ProviderRequestID} {
				attempt, err := st.GetRequestAttempt(context.Background(), request.ClientRequestID, attemptID)
				if err != nil || attempt.Disposition != AttemptDispositionActive {
					t.Fatalf("accepted attempt disposition = %#v, %v", attempt, err)
				}
			}
			if err := st.AdvanceAttemptAdmission(context.Background(), request.ClientRequestID, backup.ProviderRequestID, "accepted"); !errors.Is(err, ErrInvalidTransition) {
				t.Fatalf("admission regression error = %v", err)
			}

			terminal := c.terminal(request.ClientRequestID, primary.ProviderRequestID, 1, "error", 0)
			if _, inserted, err := claimContractTerminal(t, st, terminal, nil); err != nil || !inserted {
				t.Fatalf("terminal claim = inserted %v, err %v", inserted, err)
			}
			if err := st.AdvanceAttemptAdmission(context.Background(), request.ClientRequestID, primary.ProviderRequestID, "running"); !errors.Is(err, ErrInvalidTransition) {
				t.Fatalf("post-terminal admission error = %v", err)
			}
		})
	}
}

func TestSettlementStoreWinnerCASIsSingleAndCancelsLosers(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, primary, backup := setupSettlementRace(t, backend, st, "winner")
			selections := []WinnerSelection{
				{ClientRequestID: request.ClientRequestID, ProviderRequestID: primary.ProviderRequestID, ExpectedEpoch: 0, IngressSequence: 1},
				{ClientRequestID: request.ClientRequestID, ProviderRequestID: backup.ProviderRequestID, ExpectedEpoch: 0, IngressSequence: 2},
			}
			type result struct {
				inserted bool
				err      error
			}
			results := make(chan result, len(selections))
			var wg sync.WaitGroup
			for _, selection := range selections {
				selection := selection
				wg.Add(1)
				go func() {
					defer wg.Done()
					_, inserted, err := st.SelectRequestWinner(context.Background(), selection)
					results <- result{inserted: inserted, err: err}
				}()
			}
			wg.Wait()
			close(results)
			wins, conflicts := 0, 0
			for result := range results {
				if result.err == nil && result.inserted {
					wins++
				} else if errors.Is(result.err, ErrConflict) {
					conflicts++
				} else {
					t.Fatalf("winner CAS result = inserted %v, err %v", result.inserted, result.err)
				}
			}
			if wins != 1 || conflicts != 1 {
				t.Fatalf("winner CAS wins/conflicts = %d/%d", wins, conflicts)
			}

			stored, err := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			if err != nil || stored.WinnerAttemptID == "" {
				t.Fatalf("stored winner = %#v, %v", stored, err)
			}
			winner, loser := primary, backup
			if stored.WinnerAttemptID == backup.ProviderRequestID {
				winner, loser = backup, primary
			}
			winnerRow, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, winner.ProviderRequestID)
			loserRow, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, loser.ProviderRequestID)
			if winnerRow.Disposition != AttemptDispositionWinner || loserRow.Disposition != AttemptDispositionSpeculativeLoser ||
				loserRow.CancelState != AttemptCancelPending || loserRow.CancelReason != "speculative_loser" {
				t.Fatalf("winner/loser rows = %#v / %#v", winnerRow, loserRow)
			}

			_, _, err = st.AdvanceDeliveryCheckpoint(context.Background(), DeliveryCheckpoint{
				ClientRequestID:         request.ClientRequestID,
				ProviderRequestID:       loser.ProviderRequestID,
				IngressSequence:         stored.WinnerIngressSequence,
				TransportState:          "T1",
				ProtocolState:           "V1",
				SemanticState:           "C1",
				WrittenChunkSequence:    1,
				WrittenCompletionTokens: 1,
				WrittenCommitment:       HashSettlementSnapshot([]byte("loser")),
			})
			requireErrorIs(t, err, ErrInvalidTransition)

			next := c.attempt(request.ClientRequestID, "winner-next", "winner-next-provider", "primary", 1, 0)
			_, _, err = st.BeginAttemptBeforeDispatch(context.Background(), BeginAttemptParams{Attempt: next})
			requireErrorIs(t, err, ErrInvalidTransition)

			loserRow, _ = st.GetRequestAttempt(context.Background(), request.ClientRequestID, loser.ProviderRequestID)
			late := cancelledContractTerminal(c, request.ClientRequestID, *loserRow, stored.LastIngressSequence+1)
			if _, inserted, err := claimContractTerminal(t, st, late, nil); err != nil || !inserted {
				t.Fatalf("late loser terminal = inserted %v, err %v", inserted, err)
			}
			after, _ := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			if after.WinnerAttemptID != winner.ProviderRequestID {
				t.Fatalf("late loser changed winner: %#v", after)
			}
		})
	}
}

func TestSettlementStoreTerminalClaimIsImmutableAndIngressOrdered(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, primary, backup := setupSettlementRace(t, backend, st, "terminal")
			first := c.terminal(request.ClientRequestID, primary.ProviderRequestID, 1, "error", 0)
			stored, inserted, err := claimContractTerminal(t, st, first, nil)
			if err != nil || !inserted || stored.SnapshotHash != first.SnapshotHash {
				t.Fatalf("first terminal = %#v, inserted %v, err %v", stored, inserted, err)
			}
			_, inserted, err = claimContractTerminal(t, st, first, nil)
			if err != nil || inserted {
				t.Fatalf("terminal replay = inserted %v, err %v", inserted, err)
			}
			conflict := first
			conflictSnapshot, conflictHash := settlementSnapshot(t, map[string]any{"different": true})
			conflict.Snapshot = CanonicalSnapshot(conflictSnapshot)
			conflict.SnapshotHash = conflictHash
			_, _, err = claimContractTerminal(t, st, conflict, nil)
			requireErrorIs(t, err, ErrConflict)

			outOfOrder := c.terminal(request.ClientRequestID, backup.ProviderRequestID, 1, "error", 0)
			_, _, err = claimContractTerminal(t, st, outOfOrder, nil)
			requireErrorIs(t, err, ErrInvalidTransition)
			ordered := c.terminal(request.ClientRequestID, backup.ProviderRequestID, 2, "error", 0)
			if _, inserted, err := claimContractTerminal(t, st, ordered, nil); err != nil || !inserted {
				t.Fatalf("ordered second terminal = inserted %v, err %v", inserted, err)
			}
			final, _ := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			if final.State != RequestStateTerminalRecorded || final.LastIngressSequence != 2 {
				t.Fatalf("terminal request state = %#v", final)
			}
		})
	}
}

func TestSettlementStoreEmptyCompletionValidatesBeforeWinner(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, primary, backup := setupSettlementRace(t, backend, st, "empty")
			terminal := c.terminal(request.ClientRequestID, primary.ProviderRequestID, 1, "complete", 0)
			terminal.Envelope = "inference_complete"
			terminal.Cause = "stop"
			terminal.TerminationReason = "stop"
			selection := &WinnerSelection{
				ClientRequestID: request.ClientRequestID, ProviderRequestID: primary.ProviderRequestID,
				ExpectedEpoch: 0, IngressSequence: 1,
			}
			if _, inserted, err := claimContractTerminal(t, st, terminal, selection); err != nil || !inserted {
				t.Fatalf("empty terminal/winner = inserted %v, err %v", inserted, err)
			}
			stored, _ := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			peer, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, backup.ProviderRequestID)
			if stored.WinnerAttemptID != primary.ProviderRequestID || peer.Disposition != AttemptDispositionSpeculativeLoser {
				t.Fatalf("empty winner/peer = %#v / %#v", stored, peer)
			}

			c2, request2, primary2, _ := setupSettlementRace(t, backend, st, "empty-invalid")
			invalid := c2.terminal(request2.ClientRequestID, primary2.ProviderRequestID, 1, "complete", 1)
			invalid.Envelope = "inference_complete"
			_, _, err := claimContractTerminal(t, st, invalid, &WinnerSelection{
				ClientRequestID: request2.ClientRequestID, ProviderRequestID: primary2.ProviderRequestID,
				ExpectedEpoch: 0, IngressSequence: 1,
			})
			requireErrorIs(t, err, ErrInvalidTransition)
			if _, err := st.GetAttemptTerminal(context.Background(), request2.ClientRequestID, primary2.ProviderRequestID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("invalid empty terminal persisted: %v", err)
			}
		})
	}
}

func TestSettlementStoreRetryReleaseRequiresInvisibleQuiescentWinner(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, primary, backup := setupSettlementRace(t, backend, st, "retry")
			selection := WinnerSelection{ClientRequestID: request.ClientRequestID, ProviderRequestID: primary.ProviderRequestID, ExpectedEpoch: 0, IngressSequence: 1}
			if _, inserted, err := st.SelectRequestWinner(context.Background(), selection); err != nil || !inserted {
				t.Fatalf("select retry winner = %v/%v", inserted, err)
			}
			winnerTerminal := c.terminal(request.ClientRequestID, primary.ProviderRequestID, 2, "error", 0)
			if _, inserted, err := claimContractTerminal(t, st, winnerTerminal, nil); err != nil || !inserted {
				t.Fatalf("claim retry winner terminal = %v/%v", inserted, err)
			}
			_, _, err := st.ReleaseRequestWinnerForRetry(context.Background(), request.ClientRequestID, primary.ProviderRequestID, 0)
			requireErrorIs(t, err, ErrInvalidTransition)

			loser, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, backup.ProviderRequestID)
			loserTerminal := cancelledContractTerminal(c, request.ClientRequestID, *loser, 3)
			if _, inserted, err := claimContractTerminal(t, st, loserTerminal, nil); err != nil || !inserted {
				t.Fatalf("claim retry peer terminal = %v/%v", inserted, err)
			}
			released, changed, err := st.ReleaseRequestWinnerForRetry(context.Background(), request.ClientRequestID, primary.ProviderRequestID, 0)
			if err != nil || !changed || released.WinnerAttemptID != "" || released.WinnerEpoch != 1 {
				t.Fatalf("release winner = %#v, changed %v, err %v", released, changed, err)
			}
			_, changed, err = st.ReleaseRequestWinnerForRetry(context.Background(), request.ClientRequestID, primary.ProviderRequestID, 0)
			if err != nil || changed {
				t.Fatalf("release replay = changed %v, err %v", changed, err)
			}
			next := c.attempt(request.ClientRequestID, "retry-next", "retry-next-provider", "primary", 1, 0)
			c.beginAttempt(next, nil)

			c2, request2, primary2, backup2 := setupSettlementRace(t, backend, st, "retry-visible")
			if _, _, err := st.SelectRequestWinner(context.Background(), WinnerSelection{
				ClientRequestID: request2.ClientRequestID, ProviderRequestID: primary2.ProviderRequestID, ExpectedEpoch: 0, IngressSequence: 1,
			}); err != nil {
				t.Fatalf("select visible winner: %v", err)
			}
			if _, _, err := st.AdvanceDeliveryCheckpoint(context.Background(), DeliveryCheckpoint{
				ClientRequestID: request2.ClientRequestID, ProviderRequestID: primary2.ProviderRequestID,
				IngressSequence: 1, TransportState: "T1", ProtocolState: "V1", SemanticState: "C0",
			}); err != nil {
				t.Fatalf("visible checkpoint: %v", err)
			}
			if _, _, err := claimContractTerminal(t, st, c2.terminal(request2.ClientRequestID, primary2.ProviderRequestID, 2, "error", 0), nil); err != nil {
				t.Fatalf("visible winner terminal: %v", err)
			}
			loser2, _ := st.GetRequestAttempt(context.Background(), request2.ClientRequestID, backup2.ProviderRequestID)
			if _, _, err := claimContractTerminal(t, st, cancelledContractTerminal(c2, request2.ClientRequestID, *loser2, 3), nil); err != nil {
				t.Fatalf("visible loser terminal: %v", err)
			}
			_, _, err = st.ReleaseRequestWinnerForRetry(context.Background(), request2.ClientRequestID, primary2.ProviderRequestID, 0)
			requireErrorIs(t, err, ErrInvalidTransition)
		})
	}
}

func TestSettlementStoreFenceIsAtomicAndCancelReceiptsAreBound(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, primary, backup := setupSettlementRace(t, backend, st, "fence")
			_, _, err := st.FenceRequest(context.Background(), RequestFence{
				ClientRequestID: request.ClientRequestID, Cause: "client_gone", Sequence: 1,
				FenceVersion: 1, AttemptIDs: []string{primary.ProviderRequestID},
			})
			requireErrorIs(t, err, ErrInvalidTransition)
			unchanged, _ := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			primaryRow, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, primary.ProviderRequestID)
			if unchanged.FenceCause != "" || primaryRow.CancelState != AttemptCancelNone {
				t.Fatalf("failed fence partially mutated state: %#v / %#v", unchanged, primaryRow)
			}

			fence := RequestFence{
				ClientRequestID: request.ClientRequestID, Cause: "client_gone", Sequence: 1,
				FenceVersion: 1, AttemptIDs: []string{primary.ProviderRequestID, backup.ProviderRequestID},
			}
			stored, changed, err := st.FenceRequest(context.Background(), fence)
			if err != nil || !changed || stored.State != RequestStateFenced {
				t.Fatalf("fence = %#v, changed %v, err %v", stored, changed, err)
			}
			for _, attemptID := range fence.AttemptIDs {
				row, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, attemptID)
				if row.CancelState != AttemptCancelPending || row.FenceVersion != 1 || row.FenceSequence != 1 {
					t.Fatalf("fenced attempt = %#v", row)
				}
			}

			wrong := AttemptCancelTransition{ClientRequestID: request.ClientRequestID, ProviderRequestID: primary.ProviderRequestID, FenceVersion: 2, FenceSequence: 1, From: AttemptCancelPending, To: AttemptCancelOnWire}
			_, err = st.TransitionAttemptCancel(context.Background(), wrong)
			requireErrorIs(t, err, ErrInvalidTransition)
			onWire := wrong
			onWire.FenceVersion = 1
			changed, err = st.TransitionAttemptCancel(context.Background(), onWire)
			if err != nil || !changed {
				t.Fatalf("on-wire transition = %v/%v", changed, err)
			}
			changed, err = st.TransitionAttemptCancel(context.Background(), onWire)
			if err != nil || changed {
				t.Fatalf("on-wire replay = %v/%v", changed, err)
			}
			regress := onWire
			regress.From = AttemptCancelOnWire
			regress.To = AttemptCancelSendFailed
			_, err = st.TransitionAttemptCancel(context.Background(), regress)
			requireErrorIs(t, err, ErrInvalidTransition)

			primaryRow, _ = st.GetRequestAttempt(context.Background(), request.ClientRequestID, primary.ProviderRequestID)
			ack := cancelledContractTerminal(c, request.ClientRequestID, *primaryRow, 2)
			if _, inserted, err := claimContractTerminal(t, st, ack, nil); err != nil || !inserted {
				t.Fatalf("cancel acknowledgement = %v/%v", inserted, err)
			}
			primaryRow, _ = st.GetRequestAttempt(context.Background(), request.ClientRequestID, primary.ProviderRequestID)
			if primaryRow.CancelState != AttemptCancelAcknowledged {
				t.Fatalf("cancel acknowledgement state = %s", primaryRow.CancelState)
			}

			_, changed, err = st.FenceRequest(context.Background(), fence)
			if err != nil || changed {
				t.Fatalf("fence replay = %v/%v", changed, err)
			}
		})
	}
}

func TestSettlementStoreCheckedDeliveryCheckpointIsMonotonic(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			_, request, primary, backup := setupSettlementRace(t, backend, st, "delivery")
			if _, _, err := st.SelectRequestWinner(context.Background(), WinnerSelection{
				ClientRequestID: request.ClientRequestID, ProviderRequestID: primary.ProviderRequestID, ExpectedEpoch: 0, IngressSequence: 1,
			}); err != nil {
				t.Fatalf("select delivery winner: %v", err)
			}
			keepalive := DeliveryCheckpoint{ClientRequestID: request.ClientRequestID, IngressSequence: 2, TransportState: "T1", ProtocolState: "V0", SemanticState: "C0"}
			stored, changed, err := st.AdvanceDeliveryCheckpoint(context.Background(), keepalive)
			if err != nil || !changed || stored.ProtocolState != "V0" || stored.SemanticState != "C0" {
				t.Fatalf("keepalive checkpoint = %#v/%v/%v", stored, changed, err)
			}
			loser := DeliveryCheckpoint{
				ClientRequestID: request.ClientRequestID, ProviderRequestID: backup.ProviderRequestID, IngressSequence: 3,
				TransportState: "T1", ProtocolState: "V1", SemanticState: "C1", WrittenChunkSequence: 1,
				WrittenCompletionTokens: 1, WrittenCommitment: HashSettlementSnapshot([]byte("loser-frame")),
			}
			_, _, err = st.AdvanceDeliveryCheckpoint(context.Background(), loser)
			requireErrorIs(t, err, ErrInvalidTransition)

			winner := loser
			winner.ProviderRequestID = primary.ProviderRequestID
			winner.WrittenCompletionTokens = 2
			winner.WrittenCommitment = HashSettlementSnapshot([]byte("winner-frame"))
			stored, changed, err = st.AdvanceDeliveryCheckpoint(context.Background(), winner)
			if err != nil || !changed || stored.WrittenCompletionTokens != 2 || stored.SemanticState != "C1" {
				t.Fatalf("winner checkpoint = %#v/%v/%v", stored, changed, err)
			}
			_, changed, err = st.AdvanceDeliveryCheckpoint(context.Background(), winner)
			if err != nil || changed {
				t.Fatalf("checkpoint replay = %v/%v", changed, err)
			}
			regression := winner
			regression.IngressSequence = 4
			regression.WrittenCompletionTokens = 1
			_, _, err = st.AdvanceDeliveryCheckpoint(context.Background(), regression)
			requireErrorIs(t, err, ErrInvalidTransition)

			if _, _, err := st.FenceRequest(context.Background(), RequestFence{
				ClientRequestID: request.ClientRequestID, Cause: "client_gone", Sequence: 4, FenceVersion: 1,
				AttemptIDs: []string{primary.ProviderRequestID, backup.ProviderRequestID},
			}); err != nil {
				t.Fatalf("fence delivery request: %v", err)
			}
			beyondFence := winner
			beyondFence.IngressSequence = 5
			beyondFence.WrittenChunkSequence = 2
			beyondFence.WrittenCompletionTokens = 3
			beyondFence.WrittenCommitment = HashSettlementSnapshot([]byte("after-fence"))
			_, _, err = st.AdvanceDeliveryCheckpoint(context.Background(), beyondFence)
			requireErrorIs(t, err, ErrInvalidTransition)
		})
	}
}

func TestSettlementStoreNonStreamingDeliveryPendingRecoversIndeterminate(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c := newSettlementContract(t, backend, st)
			c.seed(1_000)
			request := c.request("nonstream", 100)
			request.Stream = false
			request = *c.beginRequest(request, false, nil)
			if _, changed, err := st.RecordDeliveryResult(context.Background(), request.ClientRequestID, "", DeliveryStatePending, nil); err != nil || !changed {
				t.Fatalf("delivery pending = %v/%v", changed, err)
			}
			snapshot, hash := settlementSnapshot(t, map[string]any{"delivery": "indeterminate", "reason": "crash_after_write"})
			stored, changed, err := st.RecordDeliveryResult(context.Background(), request.ClientRequestID, hash, DeliveryStateIndeterminate, snapshot)
			if err != nil || !changed || stored.DeliveryState != DeliveryStateIndeterminate {
				t.Fatalf("indeterminate delivery = %#v/%v/%v", stored, changed, err)
			}
			_, _, err = st.RecordDeliveryResult(context.Background(), request.ClientRequestID, hash, DeliveryStateConfirmed, snapshot)
			requireErrorIs(t, err, ErrConflict)
			_, _, err = st.AdvanceDeliveryCheckpoint(context.Background(), DeliveryCheckpoint{
				ClientRequestID: request.ClientRequestID, IngressSequence: 1,
				TransportState: "T1", ProtocolState: "V2", SemanticState: "C0",
			})
			requireErrorIs(t, err, ErrInvalidTransition)
		})
	}
}
