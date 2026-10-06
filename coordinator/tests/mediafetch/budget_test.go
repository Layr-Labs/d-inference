package mediafetch_test

import (
	"bytes"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	readbudget "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/readbudget"
)

func TestByteBudgetExactLimitAcrossConcurrentReaders(t *testing.T) {
	budget := readbudget.New(100)
	inputs := [][]byte{bytes.Repeat([]byte{'a'}, 40), bytes.Repeat([]byte{'b'}, 60)}

	var wg sync.WaitGroup
	var used atomic.Int64
	errs := make(chan error, len(inputs))
	for _, input := range inputs {
		wg.Add(1)
		go func(data []byte) {
			defer wg.Done()
			got, err := io.ReadAll(budget.Reader(bytes.NewReader(data)))
			used.Add(int64(len(got)))
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
	if used.Load() != 100 {
		t.Fatalf("used = %d, want 100", used.Load())
	}
	// Only the sentinel remains after exactly 100 consumed bytes.
	got, err := io.ReadAll(budget.Reader(bytes.NewReader([]byte("xy"))))
	if len(got) != 1 || !errors.Is(err, readbudget.ErrExceeded) {
		t.Fatalf("exact-limit budget did not retain its consumed bytes: %q, %v", got, err)
	}
}

func TestByteBudgetBoundsConcurrentOverflow(t *testing.T) {
	budget := readbudget.New(100)
	inputs := [][]byte{
		bytes.Repeat([]byte{'a'}, 80),
		bytes.Repeat([]byte{'b'}, 80),
		bytes.Repeat([]byte{'c'}, 80),
		bytes.Repeat([]byte{'d'}, 80),
	}

	var wg sync.WaitGroup
	var used atomic.Int64
	errCount := 0
	var errMu sync.Mutex
	for _, input := range inputs {
		wg.Add(1)
		go func(data []byte) {
			defer wg.Done()
			got, err := io.ReadAll(budget.Reader(bytes.NewReader(data)))
			used.Add(int64(len(got)))
			if errors.Is(err, readbudget.ErrExceeded) {
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
	if used.Load() > 101 {
		t.Fatalf("transient consumed bytes = %d, want <= limit+1 sentinel (101)", used.Load())
	}
	// A leaked reservation would wait forever rather than return the terminal
	// overflow error once every reader has finished.
	done := make(chan error, 1)
	go func() {
		_, err := io.ReadAll(budget.Reader(bytes.NewReader(nil)))
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, readbudget.ErrExceeded) {
			t.Fatalf("completed overflow budget = %v, want terminal overflow", err)
		}
	case <-time.After(time.Second):
		t.Fatal("inFlight reservations remain after readers complete")
	}
}
