package registry

// registry_metrics.go — the registry's counter sink.
//
// The registry owns the queue drain, the model-swap planner and the warm-pool
// controller, but until now had no metrics hook of its own: drain passes,
// their scans, and every load_model send were visible only as per-waiter
// stamps or Info logs, so none of the drain/warm-pool behaviour changes could
// be verified in prod after landing. The sink is the smallest interface
// *datadog.Client already satisfies (Incr/Count); api.Server installs it when
// Datadog is configured, and every emit is a nil-safe no-op otherwise.
//
// Series (constant tag sets only — never a provider id):
//
//	queue.drain.pass{trigger,outcome}   one per model per drain pass that
//	                                    popped at least one waiter
//	queue.drain.scans{trigger}          Count: fleet scans the pass performed
//	queue.drain.dominated{trigger}      Count: waiters requeued without a scan
//	                                    on a same-pass dominance verdict
//	queue.drain.suppressed{trigger}     a heartbeat drain skipped for a model
//	                                    inside the post-saturation window
//	model_load.sent{planner}            a load_model command left the registry
//
// The trigger tag is the folded DrainTrigger* vocabulary (queue.go); planner
// is loadPlannerSwap / loadPlannerWarmPool.

// registryMetricsSink is satisfied by *datadog.Client.
type registryMetricsSink interface {
	Incr(name string, tags []string)
	Count(name string, value int64, tags []string)
}

// metricsSinkBox wraps the interface so the registry can publish it with an
// atomic pointer: main.go starts the warm-pool goroutine before SetDatadog
// runs, so a plain field would race the first tick's read.
type metricsSinkBox struct{ sink registryMetricsSink }

// Planner labels for model_load.sent.
const (
	loadPlannerSwap     = "swap"      // TriggerModelSwaps (heartbeat / cold-dispatch kick)
	loadPlannerWarmPool = "warm_pool" // warm-pool controller tick
)

// Drain pass outcomes for queue.drain.pass.
const (
	drainOutcomeAdmitted  = "admitted"  // at least one waiter was handed a provider
	drainOutcomeSaturated = "saturated" // waiters were scanned, none admitted
	drainOutcomeEmpty     = "empty"     // waiters were popped but none reached a scan
)

// SetMetricsSink installs the counter sink. Pass a non-nil concrete client
// only (a typed-nil *datadog.Client would defeat the nil check here).
func (r *Registry) SetMetricsSink(sink registryMetricsSink) {
	if sink == nil {
		r.metrics.Store(nil)
		return
	}
	r.metrics.Store(&metricsSinkBox{sink: sink})
}

func (r *Registry) metricsSink() registryMetricsSink {
	if box := r.metrics.Load(); box != nil {
		return box.sink
	}
	return nil
}

// metricIncr increments a counter by one; no-op without a sink.
func (r *Registry) metricIncr(name string, tags []string) {
	if s := r.metricsSink(); s != nil {
		s.Incr(name, tags)
	}
}

// metricCount increments a counter by value; no-op without a sink or when
// value is zero (a zero Count is noise on the wire).
func (r *Registry) metricCount(name string, value int64, tags []string) {
	if value == 0 {
		return
	}
	if s := r.metricsSink(); s != nil {
		s.Count(name, value, tags)
	}
}
