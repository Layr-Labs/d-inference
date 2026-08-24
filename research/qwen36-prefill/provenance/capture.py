#!/usr/bin/env python3
"""CLI for producing one decision-grade Qwen benchmark provenance document."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from benchmark_provenance import (
    ProvenanceError,
    capture_document,
    capture_environment,
    parse_settings,
    pretty_json,
    sha256_bytes,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Capture source, artifact, model, toolchain, posture, environment, "
            "process, and stderr provenance without serializing secrets."
        )
    )
    parser.add_argument("--repo", required=True, type=Path, help="root Git worktree")
    parser.add_argument(
        "--binary", required=True, type=Path, help="exact benchmark executable"
    )
    parser.add_argument(
        "--metallib", required=True, type=Path, help="exact colocated mlx.metallib"
    )
    parser.add_argument(
        "--model-path", required=True, type=Path, help="exact model snapshot directory"
    )
    parser.add_argument(
        "--model-manifest",
        type=Path,
        help="registry manifest containing per-file SHA-256 identities",
    )
    parser.add_argument(
        "--model-snapshot-id",
        help="immutable 40-64 hex revision or sha256:<digest> for the snapshot",
    )
    parser.add_argument(
        "--config",
        action="append",
        required=True,
        type=Path,
        help="configuration file to hash; repeat for multiple files",
    )
    parser.add_argument(
        "--benchmark-setting",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="non-secret benchmark setting included in the configuration hash",
    )
    parser.add_argument(
        "--stderr-path",
        action="append",
        required=True,
        type=Path,
        help="stderr artifact path to record; repeat for every benchmark cell",
    )
    parser.add_argument(
        "--env-name",
        action="append",
        default=[],
        help="additional exact environment variable name to capture",
    )
    parser.add_argument(
        "--env-prefix",
        action="append",
        default=[],
        help="additional environment prefix to capture",
    )
    parser.add_argument(
        "--process-limit",
        type=int,
        default=30,
        help="maximum number of highest-CPU processes to retain (default: 30)",
    )
    parser.add_argument(
        "--require-exact-model-identity",
        action="store_true",
        help="fail unless model identity is pinned without reading weight payloads",
    )
    parser.add_argument(
        "--output", required=True, type=Path, help="destination provenance JSON"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        settings = parse_settings(args.benchmark_setting)
        environment = capture_environment(
            os.environ,
            extra_names=args.env_name,
            extra_prefixes=args.env_prefix,
        )
        document = capture_document(
            repo=args.repo,
            binary=args.binary,
            metallib=args.metallib,
            model_path=args.model_path,
            config_paths=args.config,
            stderr_paths=args.stderr_path,
            settings=settings,
            environment=environment,
            registry_manifest_path=args.model_manifest,
            snapshot_id=args.model_snapshot_id,
            process_limit=args.process_limit,
        )
        if (
            args.require_exact_model_identity
            and not document["model"]["identity"]["complete"]
        ):
            reason = document["model"]["identity"].get("reason", "identity incomplete")
            raise ProvenanceError(f"exact model identity required: {reason}")

        serialized = pretty_json(document)
        output = args.output.expanduser()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(serialized, encoding="utf-8")
    except (OSError, ProvenanceError, ValueError) as error:
        print(f"provenance capture failed: {error}", file=sys.stderr)
        return 2

    digest = sha256_bytes(serialized.encode("utf-8"))
    print(f"wrote {output} sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
