package readbudget

// budget.go enforces the raw per-request byte limit DURING concurrent reads.
// Checking only after each fetch returns allows Concurrency × MaxFileBytes to be
// retained transiently (32 MiB under defaults) before the 10 MiB aggregate cap
// trips. byteBudget coordinates all readers and permits at most limit+1 consumed
// bytes across them; the extra byte is solely the overflow sentinel that lets an
// exactly-at-limit response probe EOF successfully.

import (
	"errors"
	"io"
	"math"
	"sync"
)

var ErrExceeded = errors.New("mediafetch: aggregate byte budget exceeded")

type Budget struct {
	mu       sync.Mutex
	cond     *sync.Cond
	limit    int64
	capacity int64 // limit+1 overflow sentinel
	used     int64 // bytes returned to callers and retained in their result buffers
	inFlight int64 // bytes reserved by reads currently inside the underlying Reader
}

func New(limit int64) *Budget {
	capacity := limit
	if limit < math.MaxInt64 {
		capacity++
	}
	b := &Budget{limit: limit, capacity: capacity}
	b.cond = sync.NewCond(&b.mu)
	return b
}

func (b *Budget) Reader(r io.Reader) io.Reader {
	return &budgetReader{source: r, budget: b}
}

// Limit is the aggregate cap before the one-byte overflow sentinel.
func (b *Budget) Limit() int64 { return b.limit }

// reserve waits only while another reader temporarily owns all available
// budget. Once those reads finish, unused reservation is returned; consumed
// bytes remain charged. If the sentinel capacity is fully consumed there is no
// future capacity to wait for and the aggregate-overflow error is terminal.
func (b *Budget) reserve(want int) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for {
		available := b.capacity - b.used - b.inFlight
		if available > 0 {
			if int64(want) > available {
				want = int(available)
			}
			b.inFlight += int64(want)
			return want, nil
		}
		if b.inFlight == 0 {
			return 0, ErrExceeded
		}
		b.cond.Wait()
	}
}

func (b *Budget) finish(reserved, consumed int) {
	b.mu.Lock()
	b.inFlight -= int64(reserved)
	b.used += int64(consumed)
	b.cond.Broadcast()
	b.mu.Unlock()
}

type budgetReader struct {
	source io.Reader
	budget *Budget
}

func (r *budgetReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	reserved, err := r.budget.reserve(len(p))
	if err != nil {
		return 0, err
	}
	n, readErr := r.source.Read(p[:reserved])
	r.budget.finish(reserved, n)
	return n, readErr
}
