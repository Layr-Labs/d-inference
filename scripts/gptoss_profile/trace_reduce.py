#!/usr/bin/env python3
"""Reduce native MLX diagnostic events to phase/layer/operator/kernel tables.

Usage: python3 -m scripts.gptoss_profile.trace_reduce TRACE_DIR --output OUTPUT_DIR
An incomplete trace is still summarized but returns status 2.
"""

import argparse
import csv
import json
import os
from collections import Counter, defaultdict
from pathlib import Path

from .trace_schema import (OPS, TIMING_NOTE, events, interval_metrics,
                           load_object, validate_metadata)

TABLE_NAMES = ("phases", "regions", "operators", "kernels", "primitives", "descriptors")


def index_trace(path):
    regions, pipeline_names, run_info = {}, {}, {}
    for event in events(path):
        kind, values = event["kind"], event.get("values", [])
        oid = event.get("object_id", 0)
        if kind == "run_begin":
            run_info[oid] = {"target_tokens": values[0], "iteration": values[1]}
        elif kind == "chunk_begin":
            regions[("chunk", oid)] = {
                "phase": "prefill", "object_id": oid, "kind": "chunk",
                "index": values[2], "target_tokens": values[0],
                "actual_tokens": values[1], "start": values[3],
                "prefix_tokens": values[4], "run_id": event.get("context", {}).get("run_id", 0),
            }
        elif kind == "decode_step_begin":
            regions[("decode_step", oid)] = {
                "phase": "mixed" if values[4] else "decode", "kind": "decode_step",
                "object_id": oid, "index": values[0], "active_batch_size": values[1],
                "decode_rows": values[3], "prefill_rows": values[4], "chained": bool(values[6]),
                "run_id": event.get("context", {}).get("run_id", 0),
            }
        elif kind == "pipeline":
            name = event.get("name", "unknown")
            if oid not in pipeline_names or name != "unlabeled_pipeline":
                pipeline_names[oid] = name
    return regions, pipeline_names, run_info


def region_key(event, regions):
    context = event.get("context", {})
    for kind, field in (("chunk", "chunk_id"), ("decode_step", "decode_step_id")):
        key = (kind, context.get(field, 0))
        if key in regions:
            return key
    return ("unattributed", 0)


def reduce_trace(root):
    errors = []
    manifest = load_object(root / "manifest.json", errors)
    summary = load_object(root / "summary.json", errors)
    path = root / "events.ndjson"
    if not path.is_file():
        return {"valid": False, "errors": errors + ["missing events.ndjson"],
                "timing_note": TIMING_NOTE}, {}
    regions, pipelines, runs = index_trace(path)
    counts, scopes, kernels, descriptors, primitives = (defaultdict(Counter) for _ in range(5))
    stacks = defaultdict(list)
    intervals = defaultdict(list)
    event_count, unknown_dispatches, unmatched_ends = 0, 0, 0
    capture_events = Counter()
    capture_indices = defaultdict(list)
    missing_gpu_intervals = Counter()
    for event in events(path):
        event_count += 1
        kind, name = event["kind"], event.get("name", "")
        context, values = event.get("context", {}), event.get("values", [])
        region = region_key(event, regions)
        phase = regions.get(region, {}).get("phase", "unattributed")
        layer, operation = context.get("layer", -1), OPS.get(context.get("logical_op_id", 0), "unknown")
        group = (phase, layer, operation)
        counts[region][kind] += 1
        scopes[group][kind] += 1
        if kind in ("logical_scope_begin", "logical_scope_end"):
            pairing = tuple(context.get(k, 0) for k in (
                "generation", "run_id", "request_id", "chunk_id", "decode_step_id",
                "layer", "logical_op_id")) + (event.get("object_id", 0),)
            if kind.endswith("begin"):
                stacks[pairing].append(event["timestamp_ns"])
            elif stacks[pairing]:
                elapsed = event["timestamp_ns"] - stacks[pairing].pop()
                if elapsed < 0:
                    errors.append("negative logical scope interval")
                scopes[group]["graph_scope_inclusive_host_ns"] += max(0, elapsed)
            else:
                unmatched_ends += 1
        elif kind == "dispatch":
            pipeline = values[6]
            kernel = pipelines.get(pipeline, f"unknown_pipeline_{pipeline}")
            unknown_dispatches += int(pipeline not in pipelines)
            kernels[(*group, kernel, name, tuple(values[:6]))]["dispatches"] += 1
        elif kind == "primitive_begin":
            primitives[(*group, name)]["count"] += 1
        elif kind == "logical_descriptor":
            # Preserve complete schema-labelled values rather than model-specific guesses.
            descriptors[(*group, name, tuple(values))]["count"] += 1
        elif kind == "command_buffer_complete":
            if len(values) >= 2 and values[0] > 0 and values[1] >= values[0]:
                intervals[region].append((values[0], values[1]))
            else:
                missing_gpu_intervals[region] += 1
        if name.startswith("gpu_capture"):
            capture_events[name] += 1
            if name == "gpu_capture_begin":
                capture_indices["chunks"].append(event.get("object_id"))
            elif name == "gpu_capture_decode_step_begin":
                capture_indices["decode_steps"].append(values[0])
    unmatched_begins = sum(map(len, stacks.values()))
    if not event_count:
        errors.append("trace contains no events")
    if unmatched_begins or unmatched_ends:
        errors.append(f"unpaired logical scopes: begin={unmatched_begins}, end={unmatched_ends}")
    capture = validate_metadata(root, manifest, summary, event_count, errors)
    for label, kind in (("chunks", "chunk"), ("decode_steps", "decode_step")):
        observed = {region["index"] for region in regions.values() if region["kind"] == kind}
        requested = set(manifest.get("detail_selected_" + label, []))
        if not requested <= observed:
            errors.append(f"selected detail {label} indices absent from trace: {sorted(requested - observed)}")
        for index in requested & observed:
            selected_counts = [counts[key] for key, region in regions.items()
                               if region["kind"] == kind and region["index"] == index]
            if not any(row["dispatch"] and row["primitive_begin"] for row in selected_counts):
                errors.append(f"selected detail {kind} {index} lacks primitive/Metal dispatch events")
    if unknown_dispatches:
        errors.append(f"{unknown_dispatches} dispatches lack a pipeline-name association")
    for label in ("chunks", "decode_steps"):
        expected = manifest.get("gpu_capture_selected_" + label, [])
        observed = capture_indices[label]
        if expected and sorted(expected) != sorted(observed):
            errors.append(f"GPU capture {label} selection/lifecycle mismatch")
    if capture["requested"]:
        begins = capture_events["gpu_capture_begin"] + capture_events["gpu_capture_decode_step_begin"]
        ends = capture_events["gpu_capture_end"] + capture_events["gpu_capture_decode_step_end"]
        if begins == 0 or begins != ends:
            errors.append("GPU capture lifecycle is not paired")
        capture["status"] = "failed_or_incomplete" if errors else "complete_present_not_replayed"
    phase_counts, phase_intervals = defaultdict(Counter), defaultdict(list)
    for key, value in counts.items():
        phase = regions.get(key, {}).get("phase", "unattributed")
        phase_counts[phase].update(value)
        phase_intervals[phase].extend(intervals[key])
    tables = {
        "phases": [{"phase": phase, **dict(value), **interval_metrics(phase_intervals[phase])}
                   for phase, value in sorted(phase_counts.items())],
        "regions": [{**regions.get(key, {"phase": "unattributed", "kind": key[0], "object_id": key[1]}),
                     "run": runs.get(regions.get(key, {}).get("run_id"), {}),
                     "counts": dict(value), **interval_metrics(intervals[key]),
                     "missing_public_gpu_intervals": missing_gpu_intervals[key]}
                    for key, value in sorted(counts.items())],
        "operators": [{"phase": k[0], "layer": k[1], "operation": k[2], **dict(v)}
                      for k, v in sorted(scopes.items())],
        "kernels": [{"phase": k[0], "layer": k[1], "operation": k[2], "kernel": k[3],
                    "dispatch_kind": k[4], "grid": list(k[5][:3]),
                    "threadgroup": list(k[5][3:]), **dict(v)}
                    for k, v in sorted(kernels.items())],
        "primitives": [{"phase": k[0], "layer": k[1], "operation": k[2], "primitive": k[3], **dict(v)}
                       for k, v in sorted(primitives.items())],
        "descriptors": [{"phase": k[0], "layer": k[1], "operation": k[2], "name": k[3],
                        "values": dict(zip(manifest.get("event_value_layouts", {}).get(k[3],
                                          [f"value_{i}" for i in range(len(k[4]))]), k[4])), **dict(v)}
                        for k, v in sorted(descriptors.items())],
    }
    result = {"schema_version": 1, "valid": not errors, "errors": errors,
              "source": str(root), "timing_note": TIMING_NOTE, "event_count": event_count,
              "unknown_pipeline_dispatches": unknown_dispatches,
              "detail_level": manifest.get("detail_level"),
              "detail_selected_chunks": manifest.get("detail_selected_chunks", []),
              "detail_selected_decode_steps": manifest.get("detail_selected_decode_steps", []),
              "records_omitted_detail": manifest.get("records_omitted_detail"),
              "omitted_detail_by_kind": manifest.get("omitted_detail_by_kind", {}),
              "capture": capture, "capture_events": dict(capture_events), "tables": tables}
    return result, tables


def write_results(output, result, tables):
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Empty tables and failed reductions must not inherit data from a previous run.
    # Remove only this reducer's outputs, preserving other files in the directory.
    for name in TABLE_NAMES:
        (output / f"trace-{name}.csv").unlink(missing_ok=True)
    (output / "trace-reduction.json").write_text(json.dumps(result, indent=2) + "\n")
    for name, rows in tables.items():
        if not rows:
            continue
        fields = sorted(set().union(*(row.keys() for row in rows)))
        with (output / f"trace-{name}.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows({key: json.dumps(value) if isinstance(value, (dict, list)) else value
                             for key, value in row.items()} for row in rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        result, tables = reduce_trace(args.trace)
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        result, tables = {"valid": False, "errors": [str(error)], "timing_note": TIMING_NOTE}, {}
    write_results(args.output, result, tables)
    print(json.dumps({"valid": result["valid"], "errors": result["errors"], "output": str(args.output)}))
    return 0 if result["valid"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
