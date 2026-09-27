package promptcontract

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestPlanningClientTracksConfiguredWorkers(t *testing.T) {
	for _, workers := range []int{0, 4, 8, 16} {
		t.Run(fmt.Sprint(workers), func(t *testing.T) {
			s := NewSupervisor(SupervisorConfig{MaxConcurrency: workers})
			defer s.Close()
			c := s.Client()
			if c.planTransport.MaxConnsPerHost != s.config.MaxConcurrency || cap(c.planAdmission.active) != s.config.MaxConcurrency {
				t.Fatal("client and sidecar admission disagree")
			}
			if c.healthTransport == c.planTransport || c.controlTransport == c.planTransport || c.healthTransport.MaxConnsPerHost != 2 || c.controlTransport.MaxConnsPerHost != 2 {
				t.Fatal("health/control pools changed")
			}
		})
	}
}

func TestPlanAdmissionBoundsAndRefunds(t *testing.T) {
	a := newPlanAdmission(maxPendingPlans)
	var releases []func()
	for range maxPendingPlans {
		release, err := a.acquire(context.Background(), 1)
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, release)
	}
	if _, err := a.acquire(context.Background(), 1); !errors.Is(err, ErrSidecarUnavailable) {
		t.Fatal("unbounded request queue")
	}
	for _, release := range releases {
		release()
	}
	release, err := a.acquire(context.Background(), maxPendingPlanBytes)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.acquire(context.Background(), 1); !errors.Is(err, ErrSidecarUnavailable) {
		t.Fatal("unbounded queued payload bytes")
	}
	release()
	if a.pending != 0 || a.bytes != 0 || len(a.active) != 0 {
		t.Fatal("admission leaked")
	}
}

func TestPlanAdmissionCancellationAndDeadline(t *testing.T) {
	a := newPlanAdmission(1)
	owner, err := a.acquire(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	for _, cancelled := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		if cancelled {
			cancel()
		}
		_, err := a.acquire(ctx, 100)
		cancel()
		if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		if a.pending != 1 || a.bytes != 1 || len(a.active) != 1 {
			t.Fatal("cancelled waiter leaked or stole a slot")
		}
	}
	owner()
	next, err := a.acquire(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	next()
}
