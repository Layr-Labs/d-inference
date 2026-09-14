package sandboxcontrol

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxStartCleanupFailureRetainsAuthorityForDelete(t *testing.T) {
	for _, rotated := range []bool{false, true} {
		for _, failureMessage := range []bool{false, true} {
			t.Run(fmt.Sprintf("rotated=%v/host-failure=%v", rotated, failureMessage), func(t *testing.T) {
				ctx := context.Background()
				now := time.Now().UTC().Truncate(time.Millisecond)
				backend := store.NewMemory(store.Config{})
				controller := testSandboxController(backend, &now)
				stopped, _ := stoppedControllerSandbox(t, controller, backend, now)
				transport := &cancellationTestTransport{}
				session := registerStartTestHost(t, controller.hosts, stopped, transport, true)
				start, err := controller.Start(ctx, stopped.AccountID, stopped.ID, uuid.NewString())
				if err != nil {
					t.Fatal(err)
				}
				scope := protocol.SandboxScope{SandboxID: stopped.ID, Generation: stopped.Generation, FencingToken: stopped.FencingToken}
				if rotated {
					scope.FencingToken = start.RequestedFencingToken
				}
				code := runtimeCleanupFailedErrorCode
				message := protocol.SandboxDecodedMessage{Payload: &protocol.SandboxOperationStatePayload{OperationID: start.ID, Scope: scope,
					Operation: store.SandboxOperationKindStart, State: store.SandboxOperationFailed, ErrorCode: &code}}
				if failureMessage {
					message.Payload = &protocol.SandboxHostFailurePayload{OperationID: &start.ID, Scope: &scope, ErrorCode: code}
				}
				if err := controller.HandleHostMessage(ctx, session, message); err != nil {
					t.Fatal(err)
				}
				failed, err := backend.GetSandbox(ctx, stopped.AccountID, stopped.ID)
				if err != nil || failed.State != store.SandboxStateFailed || failed.FencingToken != scope.FencingToken {
					t.Fatalf("unproved stop marked stopped: %+v error=%v", failed, err)
				}
				if _, err := controller.Start(ctx, stopped.AccountID, stopped.ID, uuid.NewString()); !errors.Is(err, ErrSandboxNotReady) {
					t.Fatalf("resume accepted after unproved cleanup: %v", err)
				}
				cleanup, err := controller.Terminate(ctx, stopped.AccountID, stopped.ID, uuid.NewString())
				if err != nil || cleanup.Kind != store.SandboxOperationKindDelete || cleanup.FencingToken != scope.FencingToken {
					t.Fatalf("cleanup authority: %+v error=%v", cleanup, err)
				}
				frames := transport.frames()
				decoded, err := protocol.DecodeSandboxCoordinatorMessage(frames[len(frames)-1])
				if err != nil || decoded.Header.Type != protocol.SandboxTypeDelete {
					t.Fatalf("cleanup was not dispatched: %+v error=%v", decoded, err)
				}
			})
		}
	}
}
