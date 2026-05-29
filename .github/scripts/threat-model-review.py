#!/usr/bin/env python3
"""
Threat model PR review script.

Reads docs/threat-model.yaml and a PR diff, identifies which threats are
touched by the changed files, calls the Claude API with the focused diff,
and writes a Markdown PR comment to the output path.

Prompt caching is used on the static threat model content so repeated
pushes to the same PR pay only for the diff tokens.
"""

import argparse
import fnmatch
import sys

import anthropic
import yaml

# HTML comment used to find/update the existing PR comment on re-push
MARKER = "<!-- threat-model-review -->"

# Diff truncation limits (chars)
MAX_FILE_DIFF_CHARS = 8_000
MAX_TOTAL_DIFF_CHARS = 80_000

# ─────────────────────────────────────────────────────────────
# System prompt (prepended to the cached threat model block)
# ─────────────────────────────────────────────────────────────
SYSTEM_PREFIX = """\
You are a security-focused code reviewer embedded in a CI pipeline for the
EigenInference / darkbloom decentralized GPU inference platform.

## Platform context

Three components:
- coordinator/   Go, central matchmaker, runs on EigenCloud AMD SEV-SNP TEE
- provider-swift/ Swift CLI (darkbloom) on Apple Silicon Macs
- console-ui/    Next.js 16 frontend

Trust model: coordinator is trusted; providers and consumers are adversarial.
Inference traffic is E2E encrypted via X25519/NaCl box on the coordinator→provider leg.
Apple Secure Enclave (non-exportable P-256 key) provides hardware-bound attestation.
SIP must be enabled; disabling requires a reboot that kills the process.

## Your task

You will be given the threat model (below) and a focused PR diff.
Review the diff and write a GitHub PR comment that:

1. Opens with the exact marker line: """ + MARKER + """
2. Follows immediately with a **bold one-sentence overall verdict**.
3. Lists trust boundaries touched by this PR (TB-xxx).
4. For each relevant threat (T-xxx), states whether the change:
   - ✅ Strengthens or fixes the mitigation
   - ⚠️  Weakens or partially removes a mitigation
   - ℹ️  Neutral — touches the boundary but doesn't affect security posture
5. Flags any new attack surface introduced that is NOT covered by an existing threat.
6. Lists any SEC-* open findings this PR resolves (positive signal).

Rules:
- Be specific: cite file paths and line numbers from the diff.
- Be concise: engineers will read this, not auditors.
- Do NOT invent threats that are clearly out of scope (nation-state, supply chain).
- Do NOT repeat the threat model back. Focus on what the diff actually changes.
- If no security-relevant files changed, say so briefly (one paragraph is enough).

## Threat model
"""


def load_threat_model(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def parse_diff_by_file(diff_text: str) -> dict[str, str]:
    """Return ordered {filepath: diff_section_text}."""
    files: dict[str, str] = {}
    current_file: str | None = None
    buf: list[str] = []

    for line in diff_text.splitlines(keepends=True):
        if line.startswith("diff --git "):
            if current_file is not None:
                files[current_file] = "".join(buf)
            current_file = None
            buf = [line]
        elif line.startswith("+++ b/"):
            current_file = line[6:].strip()
            buf.append(line)
        else:
            buf.append(line)

    if current_file is not None:
        files[current_file] = "".join(buf)

    return files


def threats_for_file(filepath: str, threats: list[dict]) -> list[str]:
    """Return threat IDs whose affected_files patterns match filepath."""
    matched = []
    for t in threats:
        for pat in t.get("affected_files", []):
            if fnmatch.fnmatch(filepath, pat):
                matched.append(t["id"])
                break
    return matched


def build_focused_diff(
    file_diffs: dict[str, str], threats: list[dict]
) -> tuple[dict[str, tuple[list[str], str]], list[str]]:
    """
    Returns:
      covered   – {filepath: ([threat_ids], snippet)}  files matched by ≥1 threat
      uncovered – [filepath, ...]                       files not matched by any threat
    Respects MAX_TOTAL_DIFF_CHARS budget.
    """
    covered: dict[str, tuple[list[str], str]] = {}
    uncovered: list[str] = []
    char_budget = MAX_TOTAL_DIFF_CHARS

    for filepath, section in file_diffs.items():
        tids = threats_for_file(filepath, threats)
        if not tids:
            uncovered.append(filepath)
            continue
        if char_budget <= 0:
            # Budget exhausted — still record that the file is covered
            covered[filepath] = (tids, "[diff omitted — total diff budget exhausted]\n")
            continue
        snippet = section[:MAX_FILE_DIFF_CHARS]
        if len(section) > MAX_FILE_DIFF_CHARS:
            snippet += f"\n[...{filepath} truncated at {MAX_FILE_DIFF_CHARS} chars...]\n"
        covered[filepath] = (tids, snippet)
        char_budget -= len(snippet)

    return covered, uncovered


def build_user_message(
    covered: dict[str, tuple[list[str], str]],
    uncovered: list[str],
) -> str:
    if not covered:
        lines = [
            "No changed files matched any `affected_files` pattern in the threat model.\n",
            "**Files changed (no threat model coverage):**",
        ]
        for f in uncovered[:30]:
            lines.append(f"- `{f}`")
        if len(uncovered) > 30:
            lines.append(f"- ...and {len(uncovered) - 30} more")
        lines.append(
            "\nPlease write a brief comment noting that these changes fall outside "
            "the current threat model coverage and whether any of them introduce "
            "new trust-boundary surface that should be added to the threat model."
        )
        return "\n".join(lines)

    parts: list[str] = ["## PR file → threat mapping\n"]
    for filepath, (tids, _) in covered.items():
        parts.append(f"- `{filepath}` → {', '.join(tids)}")
    if uncovered:
        parts.append(f"\n**{len(uncovered)} files not covered by any threat pattern** (not shown in diff below):")
        for f in uncovered[:15]:
            parts.append(f"  - `{f}`")
        if len(uncovered) > 15:
            parts.append(f"  - ...and {len(uncovered) - 15} more")

    parts.append("\n## Focused diff (security-relevant files only)\n")
    for filepath, (tids, snippet) in covered.items():
        parts.append(f"### `{filepath}`  _(threats: {', '.join(tids)})_\n")
        parts.append(f"```diff\n{snippet}\n```\n")

    parts.append(
        "Review the diff above against the threat model and write the PR comment."
    )
    return "\n".join(parts)


def call_claude(system_text: str, user_message: str) -> str:
    client = anthropic.Anthropic()

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        system=[
            {
                "type": "text",
                "text": system_text,
                # Threat model content is static across PR pushes — cache it.
                "cache_control": {"type": "ephemeral"},
            }
        ],
        messages=[{"role": "user", "content": user_message}],
    )

    u = response.usage
    cache_read = getattr(u, "cache_read_input_tokens", 0)
    cache_write = getattr(u, "cache_creation_input_tokens", 0)
    print(
        f"[threat-model-review] tokens — input: {u.input_tokens}, "
        f"cache_read: {cache_read}, cache_write: {cache_write}, "
        f"output: {u.output_tokens}",
        file=sys.stderr,
    )

    return response.content[0].text


def run(threat_model_path: str, diff_path: str, output_path: str) -> None:
    model = load_threat_model(threat_model_path)
    threats: list[dict] = model.get("threats", [])

    with open(diff_path) as f:
        raw_diff = f.read()

    if not raw_diff.strip():
        with open(output_path, "w") as f:
            f.write(f"{MARKER}\n\n**Threat Model Review**: Empty diff — nothing to review.")
        return

    file_diffs = parse_diff_by_file(raw_diff)
    covered, uncovered = build_focused_diff(file_diffs, threats)

    # Build the cached system block: prefix + full threat model YAML
    threat_model_yaml = yaml.dump(
        model, default_flow_style=False, allow_unicode=True, sort_keys=False
    )
    system_text = SYSTEM_PREFIX + "\n```yaml\n" + threat_model_yaml + "\n```"

    user_message = build_user_message(covered, uncovered)
    comment = call_claude(system_text, user_message)

    # Guarantee the marker is present
    if MARKER not in comment:
        comment = MARKER + "\n\n" + comment

    # Append persistent footer
    comment += (
        "\n\n---\n"
        "*🔐 Threat model: [`docs/threat-model.yaml`](../blob/HEAD/docs/threat-model.yaml) · "
        "Updates on each push to this PR*"
    )

    with open(output_path, "w") as f:
        f.write(comment)

    print(
        f"[threat-model-review] wrote {len(comment)} chars — "
        f"covered: {len(covered)} files, uncovered: {len(uncovered)} files",
        file=sys.stderr,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate a threat-model PR review comment")
    parser.add_argument("--threat-model", required=True, help="Path to threat-model.yaml")
    parser.add_argument("--diff", required=True, help="Path to PR diff file")
    parser.add_argument("--output", required=True, help="Output path for the Markdown comment")
    args = parser.parse_args()
    run(args.threat_model, args.diff, args.output)