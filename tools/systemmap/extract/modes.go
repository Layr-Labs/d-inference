package extract

import (
	"go/types"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// Access modes, spelled the same way the artifact spells them.
const (
	ModeRead  = ir.ModeRead
	ModeWrite = ir.ModeWrite
	ModeBoth  = ir.ModeBoth
)

// readVerbs are method-name prefixes that only inspect state.
var readVerbs = []string{
	"Get", "List", "Find", "Lookup", "Fetch", "Read", "Query", "Select", "Load",
	"Snapshot", "Peek", "Count", "Len", "Size", "Has", "Is", "Contains", "Exists",
	"Stats", "Status", "State", "Info", "Describe", "Sum", "Total", "Estimate",
	"Predict", "Quote", "Compute", "Derive", "Format", "Render", "Range", "Each",
	"Iter", "All", "Current", "Active", "Available", "Allowed", "Should", "Can",
	"Resolve", "Verify", "Check", "Validate", "Match", "Score", "Rank", "Pick",
	"Choose", "Best", "Candidates", "Value", "String",
}

// writeVerbs are method-name prefixes that mutate state.
var writeVerbs = []string{
	"Set", "Save", "Insert", "Create", "Update", "Upsert", "Delete", "Remove",
	"Add", "Put", "Append", "Record", "Mark", "Increment", "Decrement", "Store",
	"Enqueue", "Push", "Register", "Unregister", "Deregister", "Release",
	"Reserve", "Cancel", "Clear", "Invalidate", "Evict", "Prune", "Purge",
	"Reset", "Commit", "Credit", "Debit", "Charge", "Settle", "Finalize",
	"Bump", "Track", "Emit", "Publish", "Send", "Write", "Rotate", "Refresh",
	"Warm", "Prefetch", "Preload", "Start", "Stop", "Close", "Open", "Begin",
	"Attach", "Detach", "Link", "Unlink", "Assign", "Revoke", "Grant", "Approve",
	"Reject", "Retire", "Rollback", "Expire", "Fail", "Complete", "Finish",
	"Apply", "Init", "Ensure", "Rebuild", "Reload", "Trim", "Drop", "Flush",
	"Merge", "Swap", "Replace", "Rename", "Move", "Copy", "Seal", "Sign",
	"Enroll", "Unenroll", "Attest", "Notify", "Broadcast", "Dispatch", "Hedge",
	"Requeue", "Retry", "Wait", "Await", "Signal", "Wake", "Tick", "Run", "Handle",
	"Process", "Consume", "Serve", "Forward",
}

// bothVerbs are read-modify-write in one call.
var bothVerbs = []string{
	"Dequeue", "Pop", "Take", "Acquire", "Claim", "GetOrCreate", "GetOrSet",
	"LoadOrStore", "FetchAndUpdate", "Next", "Reap", "Admit",
	"CompareAndSwap", "Exchange", "Pull",
}

// verbMode classifies a method name. Read verbs win over write verbs on a tie
// because Go names methods for their result ("GetOrCreate" is handled by
// bothVerbs), and the unknown case is reported as a read: the call at minimum
// observes the receiver.
func verbMode(name string) string {
	for _, v := range bothVerbs {
		if name == v || strings.HasPrefix(name, v) {
			return ModeBoth
		}
	}
	readIdx, writeIdx := -1, -1
	for _, v := range readVerbs {
		if strings.HasPrefix(name, v) {
			if len(v) > readIdx {
				readIdx = len(v)
			}
		}
	}
	for _, v := range writeVerbs {
		if strings.HasPrefix(name, v) {
			if len(v) > writeIdx {
				writeIdx = len(v)
			}
		}
	}
	switch {
	case readIdx < 0 && writeIdx < 0:
		return ModeRead
	case writeIdx > readIdx:
		return ModeWrite
	default:
		return ModeRead
	}
}

// syncMode classifies calls on the concurrency primitives that guard state, so
// a lock taken over a map is evidence about that map. Returns "" when the
// receiver is not a known primitive.
func syncMode(recv types.Type, method string) string {
	named := namedOf(recv)
	if named == nil || named.Obj().Pkg() == nil {
		return ""
	}
	pkg := named.Obj().Pkg().Path()
	switch pkg {
	case "sync":
		switch named.Obj().Name() {
		case "Mutex", "RWMutex":
			switch method {
			case "RLock", "RUnlock", "TryRLock", "RLocker":
				return ModeRead
			case "Lock", "Unlock", "TryLock":
				return ModeWrite
			}
		case "Once":
			return ModeWrite
		case "Map":
			switch method {
			case "Load", "Range", "Len":
				return ModeRead
			case "LoadOrStore", "LoadAndDelete", "Swap", "CompareAndSwap":
				return ModeBoth
			default:
				return ModeWrite
			}
		case "WaitGroup", "Cond":
			return ModeWrite
		}
	case "sync/atomic":
		switch method {
		case "Load":
			return ModeRead
		case "Store", "Add", "And", "Or":
			return ModeWrite
		case "Swap", "CompareAndSwap":
			return ModeBoth
		}
	}
	return ""
}
