// Package routingcost owns snapshot latency calculations and online calibration.
// Online per-model TTFT calibration.
//
// RawTTFTMs's constants (prefill ratio ×12, decode fallbacks) were
// measured once on an M4 Max with Qwen-7B and over-predict TTFT ~2-3× on the
// current fleet (gpt-oss-20b predicted p50 3303ms vs actual 992ms; gemma-4-26b
// 3048 vs 1638 — production inference_routes, Jun 27–Jul 3). With HARD_REJECT
// on, that bias 429s requests every eligible provider could actually have
// served. Rather than re-tune constants that will drift again, this calibrator
// learns the actual/predicted ratio ONLINE from completed requests and scales
// the live estimate by it.
//
// Design:
//
//   - Keying: per (model) and per (model, chip family). The chip-keyed ratio is
//     preferred once it has enough samples; the model-level ratio is the
//     fallback; below warm-up everywhere the ratio is 1.0 (current behavior).
//   - Robustness: the ratio is the MEDIAN of a sliding window of the most
//     recent ttftCalibrationWindowSize observations, recomputed on write and
//     cached for the (hot) read path. A cold-load outlier with a 20-30s actual
//     shifts a median by at most one rank — it cannot poison the estimate the
//     way it would poison a mean or a plain EWMA.
//   - Clamping: the APPLIED ratio is clamped to
//     [ttftCalibrationRatioMin, ttftCalibrationRatioMax] so a burst of
//     anomalous observations can never collapse the gate to zero or explode it.
//     The window stores raw ratios (clamp at apply time, not learn time) so the
//     true ratio stays observable and recovery is immediate when reality moves
//     back inside the band.
//   - Scope of the correction: only the flow portion of the estimate
//     (queued prefill + this prefill + first decode) is scaled. The cold-load
//     statePenalty (30s unknown / 20s idle_shutdown) is a load-latency proxy,
//     not a throughput estimate, and scaling it by a warm-learned ratio would
//     wrongly collapse the cold-route bias (see Policy.CalibratedTTFTMs).
//     Symmetrically, only WARM-slot predictions (StateMs == 0) are learned
//     from, so cold-load time never contaminates the ratio sample.
//   - Sample hygiene: observations are joined to the RAW (pre-calibration)
//     prediction recorded at reserve time, keyed by requestID#attempt, so the
//     feedback loop converges on the absolute ratio instead of compounding.
//     Queued requests ARE included: their prediction is made at drain-reserve
//     time (after the queue wait), so the pair is unbiased. Speculative-race
//     attempts are EXCLUDED by the API-side hook (pr.UsedBackup): the race
//     winner is the min of two draws, which would bias actuals downward.
//   - Kill switch: EIGENINFERENCE_TTFT_CALIBRATION=off returns ratio 1.0 from
//     the apply path (live-read, no restart). Learning continues while off so
//     the learned ratio stays current and observable.
//
// Registry shares one Policy across its instances and API observations. The
// policy's calibrator has its own leaf lock; prediction and observation methods
// never acquire caller locks. Startup tuning remains read-only while serving.
package routingcost
