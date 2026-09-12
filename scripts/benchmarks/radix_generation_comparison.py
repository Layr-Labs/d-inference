"""Verify benchmark comparison records without changing structural acceptance."""
import hashlib
import json


def comparison_records(report):
    rows = [(f"{key}[{i}]", row) for key in ("rows", "tenant_checks")
            for i, row in enumerate(report.get(key, []))]
    rows += [(key, report[key]) for key in ("cancel_donor", "cancelled", "recovered") if key in report]
    def tokens(value):
        return isinstance(value, list) and bool(value) and all(type(t) is int and t >= 0 for t in value)
    def digest(value):
        return hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()
    identities = {}
    def identity(path, row):
        if path not in identities:
            identities[path] = dict(path=path, **{key: row.get(key) for key in ("id", "kind", "scope", "finish", "completion_tokens")},
                                   token_ids_sha256=digest(row["token_ids"]), prompt_token_ids_sha256=digest(row["prompt_token_ids"]))
        return dict(identities[path])  # Each comparison keeps an independent value.
    result = []
    for i, (lp, left) in enumerate(rows):
        if not tokens(left.get("token_ids")) or not tokens(left.get("prompt_token_ids")):
            continue
        for rp, right in rows[i + 1:]:
            if not tokens(right.get("token_ids")) or left["prompt_token_ids"] != right.get("prompt_token_ids"):
                continue
            lt, rt = left["token_ids"], right["token_ids"]
            prefix = "cancelled" in (lp, rp)
            count = (len(lt) if lp == "cancelled" else len(rt)) if prefix else max(len(lt), len(rt))
            diff = next((i for i in range(count) if i >= len(lt) or i >= len(rt) or lt[i] != rt[i]), None)
            result.append(dict(left=identity(lp, left), right=identity(rp, right),
                               comparison="cancelled_prefix" if prefix else "exact_generated_tokens",
                               tokens_equal=diff is None, first_difference_zero_based=diff,
                               outcome="PASS" if diff is None else "FAIL"))
    return result


def policy_errors(report, expected="strict"):
    if expected not in ("strict", "record"):
        return ["invalid_generation_comparison_policy"]
    if report.get("generation_comparison_policy", "strict") != expected:
        return ["generation_comparison_policy_mismatch"]
    # Historical reports have no policy envelope and remain strict.
    if "generation_comparison_policy" not in report:
        return []
    records = comparison_records(report)
    equal = bool(records) and all(r["tokens_equal"] for r in records)
    if (report.get("generated_token_comparisons") != records
            or report.get("generated_token_comparisons_pass") is not equal
            or report.get("strict_generation_pass") is not (expected == "strict" and report.get("status") == "completed" and equal)):
        return ["generation_comparison_records_mismatch"]
    return []
