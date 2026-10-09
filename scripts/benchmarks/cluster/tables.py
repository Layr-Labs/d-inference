#!/usr/bin/env python3
"""Render Markdown tables from the cluster benchmark's JSON files.

Standard library only. Nothing is measured here; every number is read from a
file written by loadgen.py or serve_bench.py, or from the catalog JSON that
``darkbloom models catalog --json`` printed.

    tables.py catalog CATALOG.json
    tables.py cells   LABEL=SUMMARY.json [LABEL=SUMMARY.json ...]
    tables.py soak    LABEL=SUMMARY.json [...]
    tables.py memory  LABEL=SESSION.json [...]
"""

from __future__ import annotations

import json
import sys


def number(value, digits=1):
    if value is None:
        return "—"
    if isinstance(value, int):
        return f"{value:,}"
    return f"{value:,.{digits}f}"


def pick(summary, field, statistic="p50"):
    block = summary.get(field)
    return None if not block else block.get(statistic)


def catalog(path):
    models = json.load(open(path, encoding="utf-8"))
    print("| Model id | Version | Type / family | Quantization | Size GB | Files | Min RAM GB | Needs | "
          "Artifact aggregate SHA-256 |")
    print("|---|---|---|---|---:|---:|---:|---|---|")
    for model in models:
        needs = ", ".join(model.get("required_provider_capabilities") or []) or "—"
        print(f"| `{model['id']}` | {model.get('version')} | {model.get('model_type')} / "
              f"{model.get('family') or '—'} | {model.get('quantization') or '—'} | "
              f"{model.get('total_size_bytes', 0) / 1e9:.1f} | {model.get('file_count')} | "
              f"{model.get('min_ram_gb')} | {needs} | `{(model.get('aggregate_sha256') or '')[:16]}…` |")


def labelled(arguments):
    for argument in arguments:
        label, _, path = argument.partition("=")
        yield label, json.load(open(path, encoding="utf-8"))


def cells(arguments):
    print("| Run | Prompt tok (server) | Out tok | Conc. | Req ok/all | First content s p50 (p95) | "
          "Prefill tok/s p50 (client) | Decode tok/s p50 (min–max, client) | Total s p50 (p95) | "
          "Agg. out tok/s | Finish |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    for label, report in labelled(arguments):
        for cell in report.get("cells", []):
            decode = cell.get("client_decode_tps") or {}
            finish = ", ".join(f"{reason} {count}" for reason, count in (cell.get("finish_reasons") or {}).items())
            print(f"| {label} | {number(pick(cell, 'prompt_tokens'))} | {number(pick(cell, 'completion_tokens'))} | "
                  f"{cell.get('concurrency')} | {cell.get('ok')}/{cell.get('requests')} | "
                  f"{number(pick(cell, 'first_content_s'), 3)} ({number(pick(cell, 'first_content_s', 'p95'), 3)}) | "
                  f"{number(pick(cell, 'client_prefill_tps'), 0)} | "
                  f"{number(decode.get('p50'))} ({number(decode.get('min'))}–{number(decode.get('max'))}) | "
                  f"{number(pick(cell, 'total_s'), 2)} ({number(pick(cell, 'total_s', 'p95'), 2)}) | "
                  f"{number(cell.get('aggregate_output_tokens_per_second'))} | {finish or '—'} |")


def soak(arguments):
    for label, report in labelled(arguments):
        block = report.get("soak")
        if not block:
            continue
        print(f"**{label}**: {block.get('ok')}/{block.get('requests')} requests ok in "
              f"{number(block.get('wall_seconds'), 0)} s at concurrency {block.get('concurrency')}, mix "
              f"{block.get('mix')}, {block.get('max_tokens')} output tokens; failures: "
              f"{block.get('failures') or 'none'}; aggregate {number(block.get('aggregate_output_tokens_per_second'))} "
              f"output tok/s and {number(block.get('aggregate_prompt_tokens_per_second'), 0)} prompt tok/s.\n")
        print("| Minute | Requests | Failed | Out tok | Prompt tok | Decode tok/s p50 | Prefill tok/s p50 | "
              "First token s p50 |")
        print("|---:|---:|---:|---:|---:|---:|---:|---:|")
        for row in block.get("buckets", []):
            print(f"| {row['bucket']} | {row['requests']} | {row['failed']} | {number(row['output_tokens'])} | "
                  f"{number(row['prompt_tokens'])} | {number(row['client_decode_tps_p50'])} | "
                  f"{number(row['client_prefill_tps_p50'], 0)} | {number(row['first_token_s_p50'], 3)} |")
        print()
        print("| Prompt size | Req ok | First content s p50 (p95) | Prefill tok/s p50 | Decode tok/s p50 | Total s p50 (p95) |")
        print("|---:|---:|---:|---:|---:|---:|")
        for size, cell in sorted((block.get("by_size") or {}).items(), key=lambda item: int(item[0])):
            print(f"| {size} | {cell.get('ok')}/{cell.get('requests')} | "
                  f"{number(pick(cell, 'first_content_s'), 3)} ({number(pick(cell, 'first_content_s', 'p95'), 3)}) | "
                  f"{number(pick(cell, 'client_prefill_tps'), 0)} | {number(pick(cell, 'client_decode_tps'))} | "
                  f"{number(pick(cell, 'total_s'), 2)} ({number(pick(cell, 'total_s', 'p95'), 2)}) |")
        print()


def memory(arguments):
    def gib(block, key):
        value = (block or {}).get(key)
        return "—" if value is None else f"{value / (1 << 30):.2f}"

    print("| Session | Ready s | Wired GiB before / loaded / after load / after stop | Free GiB before / loaded / after stop | "
          "Process footprint GiB loaded / after load | Stop s | Exit | Left over | Failures |")
    print("|---|---:|---|---|---|---:|---:|---|---|")
    for label, record in labelled(arguments):
        before, loaded = record.get("memory_before"), record.get("memory_loaded")
        after_load, after_stop = record.get("memory_after_load"), record.get("memory_after_stop")
        print(f"| {label} | {number(record.get('listening_after_seconds'), 1)} | "
              f"{gib(before, 'wired_bytes')} / {gib(loaded, 'wired_bytes')} / {gib(after_load, 'wired_bytes')} / "
              f"{gib(after_stop, 'wired_bytes')} | {gib(before, 'free_bytes')} / {gib(loaded, 'free_bytes')} / "
              f"{gib(after_stop, 'free_bytes')} | {gib(loaded, 'process_footprint_bytes')} / "
              f"{gib(after_load, 'process_footprint_bytes')} | {number(record.get('stop_seconds'), 2)} | "
              f"{record.get('server_exit_status')} | {len(record.get('leftover_after') or [])} | "
              f"{'; '.join(record.get('failures') or []) or 'none'} |")


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 64
    command, arguments = sys.argv[1], sys.argv[2:]
    {"catalog": lambda: catalog(arguments[0]), "cells": lambda: cells(arguments),
     "soak": lambda: soak(arguments), "memory": lambda: memory(arguments)}[command]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
