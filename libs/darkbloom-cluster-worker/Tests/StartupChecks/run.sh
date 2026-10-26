#!/bin/bash
# Startup refusals of a BUILT worker binary: the two qualification switches
# cannot take effect unless the worker was started with the explicit test flag,
# the retired environment declaration of the generation mode is refused, and a
# generation mode is a closed choice. Each case starts the real worker with a
# complete, well-formed command line that names a model directory which does
# not exist: a refusal must come before anything of the model is opened, and a
# case that passes the gate must then stop at that missing directory instead.
# No model, no GPU work, no peer, no network (a failed worker's release opens
# the Metal device to reset MLX's wired limit); every case ends within a few seconds.
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
      --membership-epoch aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee --model-id "${CHECK_MODEL:-registered_qwen35_9b}" \
      --artifact-sha256 "$(sha 1)" --configuration-sha256 "$(sha 2)" \
      --peer0-id one --peer0-build-sha256 "$(sha 3)" --peer1-id two --peer1-build-sha256 "$(sha 4)" \
      --deadline-uptime-nanoseconds "$deadline" "$@" <"${CHECK_INPUT:-/dev/null}" 2>&1 >/dev/null )"
  code=$?
  set -e
  if [[ "$code" != "$status" ]]; then echo "FAILED $name: exit $code, expected $status: $out" >&2; exit 1; fi
  if [[ -n "$must" && "$out" != *"$must"* ]]; then echo "FAILED $name: stderr lacks '$must': $out" >&2; exit 1; fi
  if [[ -n "$mustnot" && "$out" == *"$mustnot"* ]]; then echo "FAILED $name: stderr has '$mustnot': $out" >&2; exit 1; fi
  if [[ -e "$missing" ]]; then echo "FAILED $name: the model directory was created" >&2; exit 1; fi
  passed=$((passed + 1)); printf 'ok %-58s %s\n' "$name" "$(printf '%s' "$out" | head -1 | cut -c1-150)"
}
transport=DARKBLOOM_CLUSTER_TRANSPORT; fault=DARKBLOOM_CLUSTER_QUALIFICATION_FAULT; retired=DARKBLOOM_CLUSTER_GENERATION_MODE
gate=DARKBLOOM_CLUSTER_QUALIFICATION_MEMORY_GATE; mimoresidency=DARKBLOOM_CLUSTER_MIMO_STAGE_RESIDENCY
steps=DARKBLOOM_CLUSTER_MIMO_STEP_EVIDENCE
residency=DARKBLOOM_CLUSTER_STAGE_RESIDENCY
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
# Tensor parallel on the dense rows; its shares only with it, two canonical weights of 1...64.
check declared-tensor-parallel-reaches-the-model 1 "" "generation mode must be" -- --generation-mode tensor_parallel_v1
check tensor-shares-reach-the-model 1 "" "tensor-shares" -- --generation-mode tensor_parallel_v1 --tensor-shares 1:3
# Tensor parallel waits on the GPU before every all-sum (the reduction is a node of the lazy graph): the worker turns
# MLX's fast fence synchronization on for itself (numerics unchanged), and only for tensor parallel; an explicit
# value from the launcher is kept (a developer A/B).
check tensor-parallel-turns-fast-synch-on 1 "darkbloom-collective-sync-v1 fast_synch=1 source=worker" "" -- --generation-mode tensor_parallel_v1
check tensor-parallel-keeps-an-explicit-fast-synch 1 "darkbloom-collective-sync-v1 fast_synch=0 source=launcher" "" MLX_METAL_FAST_SYNCH=0 -- --generation-mode tensor_parallel_v1
check pipeline-leaves-fast-synch-alone 1 "" "darkbloom-collective-sync-v1" --
# Tensor parallel lifts MLX's per-command-buffer input-size bound (whole expert banks tripped it every MoE launch);
# the operation bound stays, numerics are unchanged, and a launcher value is kept.
check tensor-parallel-lifts-the-command-buffer-size-bound 1 "darkbloom-command-buffer-budget-v1 max_mb=1000000 source=worker" "" -- --generation-mode tensor_parallel_v1
check tensor-parallel-keeps-an-explicit-command-buffer-size 1 "darkbloom-command-buffer-budget-v1 max_mb=50 source=launcher" "" MLX_MAX_MB_PER_BUFFER=50 -- --generation-mode tensor_parallel_v1
check pipeline-leaves-the-command-buffer-size-alone 1 "" "darkbloom-command-buffer-budget-v1" --
# GLM tensor parallel waits for its sums in the reading kernel by default;
# the fused fence update stays a launcher's choice (kept and logged). Qwen
# tensor parallel and GLM pipelines leave both alone.
CHECK_MODEL=registered_glm53_flash check glm-tensor-parallel-waits-in-the-reading-kernel 1 "darkbloom-fence-fusion-v1 MLX_METAL_FENCED_INPUTS=1 source=worker" "MLX_METAL_FUSED_FENCE_UPDATE" -- --generation-mode tensor_parallel_v1
CHECK_MODEL=registered_glm53_flash check glm-tensor-parallel-keeps-opted-in-sum-fences 1 "darkbloom-fence-fusion-v1 MLX_METAL_FUSED_FENCE_UPDATE=1 MLX_METAL_FENCED_INPUTS=1 source=launcher" "" MLX_METAL_FUSED_FENCE_UPDATE=1 MLX_METAL_FENCED_INPUTS=1 -- --generation-mode tensor_parallel_v1
CHECK_MODEL=registered_glm53_flash check glm-tensor-parallel-keeps-explicit-sum-fences 1 "darkbloom-fence-fusion-v1 MLX_METAL_FUSED_FENCE_UPDATE=0 MLX_METAL_FENCED_INPUTS=0 source=launcher" "" MLX_METAL_FUSED_FENCE_UPDATE=0 MLX_METAL_FENCED_INPUTS=0 -- --generation-mode tensor_parallel_v1
check qwen-tensor-parallel-leaves-the-sum-fences-alone 1 "" "darkbloom-fence-fusion-v1" -- --generation-mode tensor_parallel_v1
CHECK_MODEL=registered_glm53_flash check glm-pipeline-leaves-the-sum-fences-alone 1 "" "darkbloom-fence-fusion-v1" --
check tensor-shares-refused-without-tensor-parallel 1 "--tensor-shares takes two canonical weights" "" -- --tensor-shares 1:3
check tensor-shares-refused-malformed 1 "--tensor-shares takes two canonical weights" "" -- --generation-mode tensor_parallel_v1 --tensor-shares 1:03
check tensor-shares-refused-out-of-range 1 "--tensor-shares takes two canonical weights" "" -- --generation-mode tensor_parallel_v1 --tensor-shares 0:3
check tensor-shares-refused-three-ranks 1 "--tensor-shares takes two canonical weights" "" -- --generation-mode tensor_parallel_v1 --tensor-shares 1:1:2
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
mimo mimo-cut-outside-the-model-refused 1 "Worker requires a registered model ID, rank0|1" "" -- --cut 48
mimo mimo-every-boundary-is-in-its-row 1 "" "Worker requires a registered model ID" -- --cut 31
mimo mimo-deep-cut-is-in-its-row 1 "" "Worker requires a registered model ID" -- --cut 40
mimo mimo-phase-split-mtp-is-not-in-its-row 1 "generation mode must be one the registered model lists" "" -- --generation-mode phase_split_mtp_v1
mimo mimo-compact-mode-reaches-the-model 1 "" "generation mode must be" -- --generation-mode pipeline_compact_decode_v1
mimo mimo-has-no-recording-runtime 1 "Only the dense adapter has a recording runtime" "" -- --evidence-directory "$work/evidence"
mimo mimo-residency-switch-refused-without-the-flag 1 "$mimoresidency is a qualification switch" "" "$mimoresidency=off" --
mimo mimo-residency-switch-passes-the-gate-with-the-flag 1 "" "qualification switch" "$mimoresidency=off" -- --qualification-switches yes
mimo mimo-step-evidence-switch-refused-without-the-flag 1 "$steps is a qualification switch" "" "$steps=on" --
mimo mimo-step-evidence-switch-passes-the-gate-with-the-flag 1 "" "qualification switch" "$steps=on" -- --qualification-switches yes
mimo mimo-step-evidence-takes-only-on 1 "$steps takes only the value on" "" "$steps=yes" -- --qualification-switches yes
mimo mimo-memory-gate-switch-refused-without-the-flag 1 "$gate is a qualification switch" "" "$gate=measure" --
# No session lifetime for any model: the launch deadline is the rank lease's
# first grant, at most one grant (120 s) away, which the owner then renews.
MIMO_LIFETIME=120 mimo mimo-first-lease-grant-is-accepted 1 "" "first lease deadline" --
MIMO_LIFETIME=121 mimo mimo-beyond-one-lease-grant-is-refused 1 "first lease deadline at most 120 seconds away" "" --
MIMO_LIFETIME=1800 mimo mimo-old-row-lifetime-is-refused 1 "first lease deadline at most 120 seconds away" "" --
check keep-warm-takes-on-or-off 1 "--keep-warm takes on or off" "" -- --keep-warm maybe
check keep-warm-off-reaches-the-model 1 "" "--keep-warm" -- --keep-warm off
check residency-switch-refused-without-the-flag 1 "$residency is a qualification switch" "" "$residency=stage_wired_residency_v1" --
check residency-switch-takes-only-its-policy 1 "$residency takes only stage_wired_residency_v1" "" "$residency=on" -- --qualification-switches yes
check residency-switch-passes-the-gate-with-the-flag 1 "" "qualification switch" "$residency=stage_wired_residency_v1" -- --qualification-switches yes
# S00: before the model is opened the orphan-wired guard has decided, and a
# worker that fails leaves through the one forced exit, release first.
check orphan-guard-decides-before-the-model 1 "darkbloom-orphan-wired-v1 role=worker-rank-0 decision=" "" --
# The control reader runs from launch (it reads rank-lease renewals during the
# load), so with no usable input it may claim the exit before the load fails.
check a-failed-worker-takes-the-forced-exit 1 "darkbloom-forced-exit-v1 status=1 reason=" "" --
check the-forced-exit-resets-the-wired-limit 1 "phase=released wired_limit_before=0 wired_limit=0" "" --
# Round-4 finding 1: the prompt-prefix SSD key reaches a worker only on its input
# (`--prefix-ssd-key` names the scheme, never the key). A key, or a key file, in
# the environment is refused by name before anything else, so a launcher that
# still puts it there fails loudly instead of the key sitting in the process's
# environment, which any process of the same user can read for its whole life.
ssdscheme=darkbloom/prefix-ssd-key/input-line/v1
ssdepoch=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
ssdkey="$(printf '%064d' 0 | tr 0 a)"
ssdline() { # EPOCH RANK BASE64KEY
  printf '{"version":2,"kind":"prefixSSDKey","membershipEpoch":"%s","rank":%s,"key":"%s"}\n' "$1" "$2" "$3"
}
ssdkey32="$(head -c 32 /dev/zero | tr '\0' 'k' | base64)"
ssdline "$ssdepoch" 0 "$ssdkey32" > "$work/ssd-good"
ssdline "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee" 0 "$ssdkey32" > "$work/ssd-other-epoch"
ssdline "$ssdepoch" 1 "$ssdkey32" > "$work/ssd-other-rank"
ssdline "$ssdepoch" 0 "$(head -c 16 /dev/zero | base64)" > "$work/ssd-short-key"
printf '{"version":2,"kind":"prefixSSDKey","membershipEpoch":"%s","rank":0,"key":"%s","extra":1}\n' "$ssdepoch" "$ssdkey32" > "$work/ssd-extra-field"
check prefix-ssd-key-in-the-environment-is-refused 1 "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY is never read from the environment" "$ssdkey" \
  "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY=$ssdkey" "DARKBLOOM_CLUSTER_PREFIX_SSD_DIR=$work/ssd" --
check prefix-ssd-key-file-in-the-environment-is-refused 1 "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY_FILE is never read from the environment" "" \
  "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY_FILE=$work/key" "DARKBLOOM_CLUSTER_PREFIX_SSD_DIR=$work/ssd" --
check prefix-ssd-key-in-the-environment-is-refused-with-its-line-too 1 "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY is never read from the environment" "$ssdkey" \
  "DARKBLOOM_CLUSTER_PREFIX_SSD_KEY=$ssdkey" -- --prefix-ssd-key "$ssdscheme"
check prefix-ssd-key-argument-takes-only-its-scheme 1 "--prefix-ssd-key takes only $ssdscheme" "" -- --prefix-ssd-key yes
# (/dev/null: macOS poll reports the device invalid, so the read stops before any byte: "failed before")
check prefix-ssd-key-line-must-arrive 1 "before the prefix-SSD key" "" -- --prefix-ssd-key "$ssdscheme"
CHECK_INPUT="$work/ssd-other-epoch" check prefix-ssd-key-of-another-epoch-is-refused 1 "prefix-SSD key belongs to another epoch or rank" "$ssdkey32" -- --prefix-ssd-key "$ssdscheme"
CHECK_INPUT="$work/ssd-other-rank" check prefix-ssd-key-of-another-rank-is-refused 1 "prefix-SSD key belongs to another epoch or rank" "$ssdkey32" -- --prefix-ssd-key "$ssdscheme"
CHECK_INPUT="$work/ssd-short-key" check prefix-ssd-key-of-another-length-is-refused 1 "Invalid prefix-SSD key" "" -- --prefix-ssd-key "$ssdscheme"
CHECK_INPUT="$work/ssd-extra-field" check prefix-ssd-key-line-with-an-unknown-field-is-refused 1 "Unknown" "$ssdkey32" -- --prefix-ssd-key "$ssdscheme"
CHECK_INPUT="$work/ssd-good" check prefix-ssd-key-on-the-input-reaches-the-model 1 "" "prefix-SSD" -- --prefix-ssd-key "$ssdscheme"
printf '{"passed":true,"cases":%d,"modelOrGPUExecution":false}\n' "$passed"
