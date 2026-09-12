package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The provider terminal publishes ErrorCh before closing ChunkCh. Both select
// arms can therefore be ready together. Exercise the selected closed-chunk arm
// directly so either racer's regression fails without relying on select order.
func TestRaceClosedErrorKeepsSurvivingAttempt(t *testing.T) {
	for _, failedPrimary := range []bool{true, false} {
		name := "backup_failed"
		if failedPrimary {
			name = "primary_failed"
		}
		t.Run(name, func(t *testing.T) {
			d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 0)
			t.Cleanup(d.s.Close)
			d.provider, d.pr, d.requestID = primary, primaryPR, primaryPR.RequestID
			primaryPR.EnableSpeculativeEmptyCompletionArbitration()
			backupPR.EnableSpeculativeEmptyCompletionArbitration()
			failed, failedPR, survivor, survivorPR := backup, backupPR, primary, primaryPR
			resolveChunk := d.resolveBackupRaceChunk
			if failedPrimary {
				failed, failedPR, survivor, survivorPR = primary, primaryPR, backup, backupPR
				resolveChunk = d.resolvePrimaryRaceChunk
			}
			d.s.handleInferenceError(failed.ID, failed, &protocol.InferenceErrorMessage{
				RequestID: failedPR.RequestID,
				Error:     "provider failed before content", StatusCode: http.StatusInternalServerError,
			})
			var chunk registry.ProviderChunk
			var ok bool
			select {
			case chunk, ok = <-failedPR.ChunkCh:
			default:
				t.Fatal("returned terminal handler left the chunk stream open")
			}
			if ok || len(failedPR.ErrorCh) != 1 || failed.GetPending(failedPR.RequestID) != nil {
				t.Fatal("terminal did not publish the expected closed chunk, queued error, and removed attempt")
			}
			const content = `{"choices":[{"delta":{"content":"surviving response"}}]}`
			survivorPR.ChunkCh <- registry.ProviderChunk{Data: content, ReceivedAt: time.Now()}
			if got := resolveChunk(chunk, ok, backup, backupPR, nil); got != outcomeCommitted {
				t.Errorf("outcome = %v, want committed survivor", got)
			}
			if d.provider != survivor || d.pr != survivorPR || d.requestID != survivorPR.RequestID || d.firstChunk != content {
				t.Errorf("survivor was not promoted with its content: provider=%p pending=%p request=%q chunk=%q", d.provider, d.pr, d.requestID, d.firstChunk)
			}
			if got := survivor.GetPending(survivorPR.RequestID); got != survivorPR {
				t.Errorf("survivor pending = %p, want %p; a failed racer must not cancel the live attempt", got, survivorPR)
			}
			if backupPR.BackupWon.Load() != failedPrimary {
				t.Error("backup winner state does not match the surviving provider")
			}
			// A sole survivor may later complete without text. Its settlement
			// decision must be accepted, not cancelled or left waiting forever.
			decision := make(chan bool, 1)
			t.Cleanup(func() { survivorPR.ResolveSpeculativeEmptyCompletion(false) })
			go func() {
				accepted, waited := survivorPR.AwaitSpeculativeEmptyCompletionDecision()
				decision <- accepted && waited
			}()
			select {
			case accepted := <-decision:
				if !accepted {
					t.Error("surviving attempt was denied empty-completion settlement")
				}
			case <-time.After(time.Second):
				t.Fatal("surviving attempt still waits for a race decision")
			}
		})
	}
}

func TestRunRaceQueuedErrorKeepsSurvivingAttempt(t *testing.T) {
	for _, failedPrimary := range []bool{true, false} {
		name := "backup_failed"
		if failedPrimary {
			name = "primary_failed"
		}
		t.Run(name, func(t *testing.T) {
			d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 0)
			t.Cleanup(d.s.Close)
			d.provider, d.pr, d.requestID = primary, primaryPR, primaryPR.RequestID
			failed, failedPR, survivor, survivorPR := backup, backupPR, primary, primaryPR
			if failedPrimary {
				failed, failedPR, survivor, survivorPR = primary, primaryPR, backup, backupPR
			}
			d.s.handleInferenceError(failed.ID, failed, &protocol.InferenceErrorMessage{
				RequestID: failedPR.RequestID,
				Error:     "provider failed before content", StatusCode: http.StatusInternalServerError,
			})
			const content = `{"choices":[{"delta":{"content":"surviving response"}}]}`
			survivorPR.ChunkCh <- registry.ProviderChunk{Data: content, ReceivedAt: time.Now()}
			// Any of the three ready arms may win select. They must all keep
			// the healthy attempt and deliver its own buffered content.
			if got := d.runRace(backup, backupPR); got != outcomeCommitted {
				t.Fatalf("outcome = %v, want committed survivor", got)
			}
			if d.provider != survivor || d.pr != survivorPR || d.firstChunk != content || survivor.GetPending(survivorPR.RequestID) != survivorPR {
				t.Fatal("race abandoned the survivor or selected a failed attempt")
			}
		})
	}
}

func TestRaceChunkWinnerStillCancelsLoser(t *testing.T) {
	for _, winnerName := range []string{"primary", "backup"} {
		for _, terminal := range []string{"content", "empty_completion", "content_then_error"} {
			t.Run(winnerName+"/"+terminal, func(t *testing.T) {
				d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 0)
				t.Cleanup(d.s.Close)
				d.provider, d.pr, d.requestID = primary, primaryPR, primaryPR.RequestID
				winner, winnerPR, loser, loserPR := primary, primaryPR, backup, backupPR
				resolveChunk, resolveError := d.resolvePrimaryRaceChunk, d.resolvePrimaryRaceError
				if winnerName == "backup" {
					winner, winnerPR, loser, loserPR = backup, backupPR, primary, primaryPR
					resolveChunk, resolveError = d.resolveBackupRaceChunk, d.resolveBackupRaceError
				}
				const content = `{"choices":[{"delta":{"content":"winning response"}}]}`
				chunk := registry.ProviderChunk{Data: content, ReceivedAt: time.Now()}
				var got dispatchOutcome
				if terminal == "content_then_error" {
					winnerPR.ChunkCh <- chunk
					d.s.handleInferenceError(winner.ID, winner, &protocol.InferenceErrorMessage{
						RequestID: winnerPR.RequestID,
						Error:     "failed after buffered content", StatusCode: http.StatusInternalServerError,
					})
					var errMsg protocol.InferenceErrorMessage
					select {
					case errMsg = <-winnerPR.ErrorCh:
					default:
						t.Fatal("returned terminal handler did not publish its error")
					}
					got = resolveError(errMsg, backup, backupPR, nil)
					if d.initialError == nil || d.initialError.Error != errMsg.Error {
						t.Error("buffered content lost its later terminal error")
					}
				} else {
					got = resolveChunk(chunk, terminal == "content", backup, backupPR, nil)
				}
				if got != outcomeCommitted || !d.committed || d.provider != winner || d.pr != winnerPR || d.requestID != winnerPR.RequestID {
					t.Fatal("content or clean completion did not commit its winning attempt")
				}
				if loser.GetPending(loserPR.RequestID) != nil {
					t.Error("winner left its losing attempt running")
				}
				wantContent := content
				if terminal == "empty_completion" {
					wantContent = ""
				}
				if d.firstChunk != wantContent || backupPR.BackupWon.Load() != (winnerName == "backup") {
					t.Error("winner content or backup attribution changed")
				}
			})
		}
	}
}
