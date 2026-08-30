package api

import (
	"fmt"
	"testing"
	"time"
)

func TestReceiptCacheBoundedFIFO(t *testing.T) {
	c := newReceiptCache()
	for i := 0; i < receiptCacheCap+10; i++ {
		c.put(&storedReceipt{
			Address:   fmt.Sprintf("addr-%d", i),
			CreatedAt: time.Now(),
		})
	}
	if len(c.byKa) != receiptCacheCap || len(c.order) != receiptCacheCap {
		t.Fatalf("cache size = %d/%d, want %d", len(c.byKa), len(c.order), receiptCacheCap)
	}
	if _, ok := c.get("addr-0"); ok {
		t.Error("oldest receipt should have been evicted")
	}
	if _, ok := c.get(fmt.Sprintf("addr-%d", receiptCacheCap+9)); !ok {
		t.Error("newest receipt missing")
	}

	// Re-putting an existing address must not grow the ring.
	before := len(c.order)
	c.put(&storedReceipt{Address: fmt.Sprintf("addr-%d", receiptCacheCap+9)})
	if len(c.order) != before {
		t.Errorf("re-put grew the eviction ring: %d -> %d", before, len(c.order))
	}
}
