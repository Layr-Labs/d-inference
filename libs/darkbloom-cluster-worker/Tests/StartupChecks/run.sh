#!/bin/bash
# Startup refusals of a BUILT worker binary: the two qualification switches
# cannot take effect unless the worker was started with the explicit test flag,
# the retired environment declaration of the generation mode is refused, and a
# generation mode is a closed choice. Each case starts the real worker with a
# complete, well-formed command line that names a model directory which does
# not exist: a refusal must come before anything of the model is opened, and a
# case that passes the gate must then stop at that missing directory instead.
# No model, no GPU, no peer, no network; every case ends within a few seconds.
#
# usage: run.sh /ABS/PATH/darkbloom-cluster-worker
set -euo pipefail
worker="${1:?usage: run.sh /ABS/PATH/darkbloom-cluster-worker}"
[[ "$worker" == /* && -x "$worker" ]] || { echo "expected an absolute path to an executable worker" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/cluster-startup-checks.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
missing="$work/no-such-model"
sha() { printf '%064d' "$1" | tr '0-9' 'a-j' | cut -c1-64 | tr 'g-j' 'a-d'; }
passed=0
# case NAME EXPECTED_STATUS MUST_CONTAIN MUST_NOT_CONTAIN [ENV=VALUE ...] -- [extra worker arguments]
check() {
  local name="$1" status="$2" must="$3" mustnot="$4"; shift 4
  local environment=()
  while [[ "$1" != -- ]]; do environment+=("$1"); shift; done
  shift
  local now deadline out code
  now="$("$worker" --uptime-nanoseconds)"
  deadline=$((now + 20000000000))
  set +e
  out="$( /usr/bin/env -i PATH=/usr/bin:/bin DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1 \
      JACCL_RANK=0 JACCL_COORDINATOR=127.0.0.1:1 JACCL_IBV_DEVICES="$work/devices.json" ${environment[@]+"${environment[@]}"} \
      "$worker" --model-dir "$missing" --rank 0 --stage-cut 8 \
      --membership-epoch aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee --model-id registered_qwen35_9b \
      --artifact-sha256 "$(sha 1)" --configuration-sha256 "$(sha 2)" \
      --peer0-id one --peer0-build-sha256 "$(sha 3)" --peer1-id two --peer1-build-sha256 "$(sha 4)" \
      --deadline-uptime-nanoseconds "$deadline" "$@" </dev/null 2>&1 >/dev/null )"
  code=$?
  set -e
  if [[ "$code" != "$status" ]]; then echo "FAILED $name: exit $code, expected $status: $out" >&2; exit 1; fi
  if [[ -n "$must" && "$out" != *"$must"* ]]; then echo "FAILED $name: stderr lacks '$must': $out" >&2; exit 1; fi
  if [[ -n "$mustnot" && "$out" == *"$mustnot"* ]]; then echo "FAILED $name: stderr has '$mustnot': $out" >&2; exit 1; fi
  if [[ -e "$missing" ]]; then echo "FAILED $name: the model directory was created" >&2; exit 1; fi
  passed=$((passed + 1)); printf 'ok %-58s %s\n' "$name" "$(printf '%s' "$out" | head -1 | cut -c1-150)"
}
transport=DARKBLOOM_CLUSTER_TRANSPORT; fault=DARKBLOOM_CLUSTER_QUALIFICATION_FAULT; retired=DARKBLOOM_CLUSTER_GENERATION_MODE
gate=DARKBLOOM_CLUSTER_QUALIFICATION_MEMORY_GATE; residency=DARKBLOOM_CLUSTER_MIMO_STAGE_RESIDENCY
# With no switch the worker gets as far as the missing model: the baseline every refusal is told apart from.
check baseline-stops-at-the-missing-model 1 "" "qualification switch" --
check transport-switch-refused-without-the-flag 1 "$transport is a qualification switch" "" "$transport=local-socket-test" --
check transport-switch-refused-whatever-its-value 1 "$transport is a qualification switch" "" "$transport=" --
check fault-switch-refused-without-the-flag 1 "$fault is a qualification switch" "" "$fault=handoff_corrupt_segment=3" --
check both-switches-refused-without-the-flag 1 "is a qualification switch" "" "$transport=local-socket-test" "$fault=handoff_stall_after_segment=2:1500" --
check refusal-names-the-flag 1 "--qualification-switches yes" "" "$transport=local-socket-test" --
check transport-switch-passes-the-gate-with-the-flag 1 "" "qualification switch" "$transport=local-socket-test" -- --qualification-switches yes
check fault-switch-passes-the-gate-with-the-flag 1 "" "qualification switch" "$fault=handoff_corrupt_segment=3" -- --qualification-switches yes
check flag-alone-changes-nothing 1 "" "qualification switch" -- --qualification-switches yes
check flag-takes-only-yes 1 "takes only the value yes" "" -- --qualification-switches no
# The host memory gate's record and measure modes are a qualification switch like the other two.
check memory-gate-switch-refused-without-the-flag 1 "$gate is a qualification switch" "" "$gate=measure" --
check memory-gate-switch-refused-whatever-its-value 1 "$gate is a qualification switch" "" "$gate=" --
check memory-gate-switch-passes-the-gate-with-the-flag 1 "" "qualification switch" "$gate=measure" -- --qualification-switches yes
check memory-gate-record-refused-without-the-flag 1 "$gate is a qualification switch" "" "$gate=record" --
check memory-gate-record-passes-the-gate-with-the-flag 1 "" "qualification switch" "$gate=record" -- --qualification-switches yes
check retired-mode-name-refused 1 "$retired is no longer read" "" "$retired=phase_split_v1" --
check retired-mode-name-refused-even-with-the-flag 1 "$retired is no longer read" "" "$retired=phase_split_v1" -- --qualification-switches yes
check unknown-generation-mode-refused 1 "generation mode must be one the registered model lists" "" -- --generation-mode phase-split
check declared-generation-mode-reaches-the-model 1 "" "generation mode must be" -- --generation-mode phase_split_v1
check declared-compact-mode-reaches-the-model 1 "" "generation mode must be" -- --generation-mode pipeline_compact_decode_v1
# A second registered model: MiMo's own row decides its cuts, its modes and its qualification switch.
mimo() { # NAME EXPECTED_STATUS MUST_CONTAIN MUST_NOT_CONTAIN [ENV=VALUE ...] -- [extra worker arguments]
  local name="$1" status="$2" must="$3" mustnot="$4"; shift 4
  local environment=()
  while [[ "$1" != -- ]]; do environment+=("$1"); shift; done
  shift
  local cut=32
  if [[ "${1:-}" == --cut ]]; then cut="$2"; shift 2; fi
  local now deadline out code
  now="$("$worker" --uptime-nanoseconds)"
  deadline=$((now + ${MIMO_LIFETIME:-20}000000000))
  set +e
  out="$( /usr/bin/env -i PATH=/usr/bin:/bin MLX_ENABLE_TF32=1 \
      JACCL_RANK=0 JACCL_COORDINATOR=127.0.0.1:1 JACCL_IBV_DEVICES="$work/devices.json" ${environment[@]+"${environment[@]}"} \
      "$worker" --model-dir "$missing" --rank 0 --stage-cut "$cut" \
      --membership-epoch aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee --model-id registered_mimo_v26_flash_mopd \
      --artifact-sha256 "$(sha 1)" --configuration-sha256 "$(sha 2)" \
      --peer0-id one --peer0-build-sha256 "$(sha 3)" --peer1-id two --peer1-build-sha256 "$(sha 4)" \
      --deadline-uptime-nanoseconds "$deadline" "$@" </dev/null 2>&1 >/dev/null )"
  code=$?
  set -e
  if [[ "$code" != "$status" ]]; then echo "FAILED $name: exit $code, expected $status: $out" >&2; exit 1; fi
  if [[ -n "$must" && "$out" != *"$must"* ]]; then echo "FAILED $name: stderr lacks '$must': $out" >&2; exit 1; fi
  if [[ -n "$mustnot" && "$out" == *"$mustnot"* ]]; then echo "FAILED $name: stderr has '$mustnot': $out" >&2; exit 1; fi
  if [[ -e "$missing" ]]; then echo "FAILED $name: the model directory was created" >&2; exit 1; fi
  passed=$((passed + 1)); printf 'ok %-58s %s\n' "$name" "$(printf '%s' "$out" | head -1 | cut -c1-150)"
}
mimo mimo-baseline-stops-at-the-missing-model 1 "" "Worker requires a registered model ID" --
mimo mimo-unlisted-cut-refused 1 "Worker requires a registered model ID, rank0|1" "" -- --cut 31
mimo mimo-deep-cut-is-in-its-row 1 "" "Worker requires a registered model ID" -- --cut 40
mimo mimo-phase-split-is-not-in-its-row 1 "generation mode must be one the registered model lists" "" -- --generation-mode phase_split_v1
mimo mimo-compact-mode-reaches-the-model 1 "" "generation mode must be" -- --generation-mode pipeline_compact_decode_v1
mimo mimo-has-no-recording-runtime 1 "Only the dense adapter has a recording runtime" "" -- --evidence-directory "$work/evidence"
mimo mimo-residency-switch-refused-without-the-flag 1 "$residency is a qualification switch" "" "$residency=off" --
mimo mimo-residency-switch-passes-the-gate-with-the-flag 1 "" "qualification switch" "$residency=off" -- --qualification-switches yes
mimo mimo-memory-gate-switch-refused-without-the-flag 1 "$gate is a qualification switch" "" "$gate=measure" --
# Its own session bound: longer than the dense rows' 300 s, and not unbounded.
MIMO_LIFETIME=1800 mimo mimo-lifetime-of-its-row-is-accepted 1 "" "local lifetime" --
MIMO_LIFETIME=1801 mimo mimo-lifetime-beyond-its-row-is-refused 1 "<=1800-second local lifetime" "" --
printf '{"passed":true,"cases":%d,"modelOrGPUExecution":false}\n' "$passed"
