package promptcontract_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
	production "github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestPlanningClientTracksConfiguredWorkers(t *testing.T) {
	for _, workers := range []int{0, 4, 8, 16} {
		t.Run(fmt.Sprint(workers), func(t *testing.T) {
			d := newClientDependencies(t)
			s := production.NewSupervisor(production.SupervisorConfig{MaxConcurrency: workers,
				PlanAdmissions: d.planAdmissions, Transports: d.transports})
			defer s.Close()
			// The supervisor configures the sidecar's workers; unset uses the default.
			configured := workers
			if configured == 0 {
				configured = sidecar.DefaultMaxConcurrency
			}
			if d.pool(sidecar.PoolPlan).MaxConnsPerHost != configured || d.planAdmission().Workers() != configured {
				t.Fatal("client and sidecar admission disagree")
			}
			plan, health, control := d.pool(sidecar.PoolPlan), d.pool(sidecar.PoolHealth), d.pool(sidecar.PoolControl)
			if health == plan || control == plan || health.MaxConnsPerHost != 2 || control.MaxConnsPerHost != 2 {
				t.Fatal("health/control pools changed")
			}
		})
	}
}

func TestPlanAdmissionBoundsAndRefunds(t *testing.T) {
	a := sidecar.NewPlanAdmission(sidecar.MaxPendingPlans)
	var releases []func()
	for range sidecar.MaxPendingPlans {
		release, err := a.Acquire(context.Background(), 1)
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, release)
	}
	if _, err := a.Acquire(context.Background(), 1); !errors.Is(err, sidecar.ErrSidecarUnavailable) {
		t.Fatal("unbounded request queue")
	}
	for _, release := range releases {
		release()
	}
	release, err := a.Acquire(context.Background(), sidecar.MaxPendingPlanBytes)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Acquire(context.Background(), 1); !errors.Is(err, sidecar.ErrSidecarUnavailable) {
		t.Fatal("unbounded queued payload bytes")
	}
	release()
	if a.PendingPlans() != 0 || a.PendingBytes() != 0 || a.ActivePlans() != 0 {
		t.Fatal("admission leaked")
	}
}

func TestPlanAdmissionCancellationAndDeadline(t *testing.T) {
	a := sidecar.NewPlanAdmission(1)
	owner, err := a.Acquire(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	for _, cancelled := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		if cancelled {
			cancel()
		}
		_, err := a.Acquire(ctx, 100)
		cancel()
		if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		if a.PendingPlans() != 1 || a.PendingBytes() != 1 || a.ActivePlans() != 1 {
			t.Fatal("cancelled waiter leaked or stole a slot")
		}
	}
	owner()
	next, err := a.Acquire(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	next()
}
