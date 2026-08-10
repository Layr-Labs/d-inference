package mediafetch

import (
	"bytes"
	"errors"
	"io"
	"sync"
	"testing"
)

func TestByteBudgetExactLimitAcrossConcurrentReaders(t *testing.T) {
	budget := newByteBudget(100)
	inputs := [][]byte{bytes.Repeat([]byte{'a'}, 40), bytes.Repeat([]byte{'b'}, 60)}

	var wg sync.WaitGroup
	errs := make(chan error, len(inputs))
	for _, input := range inputs {
		wg.Add(1)
		go func(data []byte) {
			defer wg.Done()
			got, err := io.ReadAll(budget.reader(bytes.NewReader(data)))
			if err == nil && len(got) != len(data) {
				err = errors.New("short exact-limit read")
			}
			errs <- err
		}(input)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("exact aggregate limit must succeed: %v", err)
		}
	}
	if budget.used != 100 {
		t.Fatalf("used = %d, want 100", budget.used)
	}
}

func TestByteBudgetBoundsConcurrentOverflow(t *testing.T) {
	budget := newByteBudget(100)
	inputs := [][]byte{
		bytes.Repeat([]byte{'a'}, 80),
		bytes.Repeat([]byte{'b'}, 80),
		bytes.Repeat([]byte{'c'}, 80),
		bytes.Repeat([]byte{'d'}, 80),
	}

	var wg sync.WaitGroup
	errCount := 0
	var errMu sync.Mutex
	for _, input := range inputs {
		wg.Add(1)
		go func(data []byte) {
			defer wg.Done()
			_, err := io.ReadAll(budget.reader(bytes.NewReader(data)))
			if errors.Is(err, errAggregateBudgetExceeded) {
				errMu.Lock()
				errCount++
				errMu.Unlock()
			}
		}(input)
	}
	wg.Wait()
	if errCount == 0 {
		t.Fatal("aggregate overflow must fail at least one reader")
	}
	if budget.used > 101 {
		t.Fatalf("transient consumed bytes = %d, want <= limit+1 sentinel (101)", budget.used)
	}
	if budget.inFlight != 0 {
		t.Fatalf("inFlight = %d after readers complete, want 0", budget.inFlight)
	}
}
