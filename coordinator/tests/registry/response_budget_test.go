package registry_test

import (
	"sync"
	"sync/atomic"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestResponseBudgetBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name  string
		sizes []int
		want  []bool
	}{
		{"bytes", []int{3, 1, 1, 0}, []bool{true, true, false, false}},
		{"empty frames", []int{0, 0, 0, 0}, []bool{true, true, true, false}},
		{"oversized first", []int{5, 1}, []bool{false, false}},
		{"negative", []int{-1, 0}, []bool{false, false}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := production.NewResponseBudget(4, 3)
			for i, n := range tc.sizes {
				if got := b.Accept(n); got != tc.want[i] {
					t.Fatalf("Accept(%d)=%v want %v", n, got, tc.want[i])
				}
			}
		})
	}
}

func TestResponseBudgetConcurrent(t *testing.T) {
	b := production.NewResponseBudget(100, 100)
	var accepted atomic.Int64
	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if b.Accept(1) {
				accepted.Add(1)
			}
		}()
	}
	wg.Wait()
	if accepted.Load() != 100 {
		t.Fatalf("accepted %d", accepted.Load())
	}
}
