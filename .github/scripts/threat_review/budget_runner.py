"""Budgeted advisory lifecycle; trusted checkout only and durable partial reports."""
import re
from urllib.parse import quote
from .client import GitHub, ReviewUnavailable
from .budget_scan import Scanner, failure
from .context import ThreatContext
from .paid import PaidCalls
from .report import MARKER, LEGACY_MARKER, COMMENT_LIMIT, render
from .runner import same_revision, verify_diff
from .source import complete_files
from .state import State


def status_body(repository, head, base, diff_base, snapshot, evidence, history=None):
    errors = snapshot.get("errors", [])
    complete = (snapshot.get("integration_completed", False)
                and snapshot.get("covered_units") == snapshot.get("total_units")
                and not snapshot.get("limited_files") and not errors
                and not snapshot.get("depth_batches_pending"))
    progress = ("First pass completed; selected deeper review is pending" if snapshot.get("integration_completed")
                else "Review in progress; coverage is not complete")
    error = None if complete else "; ".join(errors) or progress
    body = render(repository, head, base, "budgeted Sonnet / selective Opus / selective Astra",
                  snapshot.get("findings", []), evidence, snapshot.get("limited_files", []),
                  error, diff_base, snapshot.get("outcomes", []))
    # The legacy renderer's full-text-model claim does not describe this engine.
    body = re.sub(r"(?m)^Coverage: .*", "", body)
    body += (f"\n\nCoverage: {snapshot.get('covered_units', 0)}/{snapshot.get('total_units', 0)} source units; "
             f"cross-file integration {'complete' if snapshot.get('integration_completed') else 'pending'}. "
             f"{snapshot.get('depth_batches_pending', 0)} selected depth batch(es) pending. "
             "All threat definitions indexed; relevant full definitions selected. Unchanged callers are not scanned."
             f"\n\nCost this run: **${snapshot.get('actual_usd', 0):.4f} reported**, "
             f"**${snapshot.get('unreconciled_reserved_usd', 0):.4f} reserved with unknown cost**; "
             f"{snapshot.get('requests', 0)} paid request(s), {snapshot.get('reused_batches', 0)} reused batch(es), "
             f"{snapshot.get('provider_cached_tokens', 0)} provider cache-hit tokens.")
    if history:
        body += f"\n\n[Saved findings and earlier report]({history}) · Historical findings are not confirmed resolved."
    return body


def run(event, root, env, github=None, state=None, paid_factory=PaidCalls):
    repository = event["repository"]["full_name"]
    pr = event["pull_request"]
    head, base, number = pr["head"]["sha"], pr["base"]["sha"], pr["number"]
    base_ref = pr["base"]["ref"]
    run_id = f"{env['GITHUB_RUN_ID']}-{env.get('GITHUB_RUN_ATTEMPT', '1')}"
    if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
            or not all(re.fullmatch(r"[a-f0-9]{40}", sha) for sha in (head, base))
            or type(number) is not int or number <= 0 or not re.fullmatch(r"[0-9]+-[0-9]+", run_id)):
        raise ReviewUnavailable("Invalid review identity")
    github = github or GitHub(repository, number, env["GH_TOKEN"])
    state = state or State(GitHub(repository, number, env["THREAT_REVIEW_STATE_TOKEN"])
                           if env.get("THREAT_REVIEW_STATE_TOKEN") else github)
    if pr.get("draft"):
        return "Skipped: draft PR."
    current = github.pull()
    if not same_revision(current, head, base_ref):
        return "Skipped: PR revision changed or PR closed."
    existing = github.existing_comment((MARKER, LEGACY_MARKER))
    previous = (existing or {}).get("body", "")
    evidence, diff_base, history = {}, None, None
    snapshot = {"errors": [], "findings": []}
    scanner = None
    publication_uncertain = False

    def alive():
        current = github.pull()
        if not same_revision(current, head, base_ref):
            raise ReviewUnavailable("PR revision changed")
        if diff_base:
            verify_diff(github, current, base, head, diff_base)

    def publish():
        nonlocal existing, publication_uncertain
        if publication_uncertain:
            # A timed-out POST can have created a comment. Prove its identity
            # before retrying; a failed lookup must never authorize another POST.
            existing = github.existing_comment((MARKER, LEGACY_MARKER))
        alive()
        body = status_body(repository, head, base, diff_base, snapshot, evidence, history)
        if previous and not history:
            # No durable write succeeded: preserve old findings inline instead
            # of replacing paid work with an infrastructure failure notice.
            body += "\n\n<details><summary>Previous review (not confirmed resolved)</summary>\n\n" + previous + "\n</details>"
        if len(body) > COMMENT_LIMIT:
            if not history:
                return  # retain the old comment; the Actions summary has status
            body = status_body(repository, head, base, diff_base,
                               dict(snapshot, findings=[], errors=["Report exceeds comment capacity; see saved findings"]),
                               evidence, history)
        publication_uncertain = True
        result = github.publish(existing, body)
        publication_uncertain = False
        if result:
            existing = result

    def checkpoint(value):
        nonlocal snapshot, history
        snapshot = value
        # Save even when the PR head moved. Publication alone needs a live head.
        history = state.checkpoint(run_id, {"repository": repository, "head": head, "base": base,
                                           "diff_base": diff_base, "previous_comment": previous,
                                           "review": snapshot})
        publish()

    try:
        if env.get("THREAT_REVIEW_ENABLED") != "true":
            snapshot["errors"] = ["Paid review is paused. Budgeted pilot must be explicitly enabled by a maintainer"]
            publish()
            return "Paid review paused; no provider requests made."
        # A normal PR cannot request expensive depth by adding text or a label.
        # Dispatch is the only override, checked against current permissions.
        force_deep = event.get("review_depth") == "deep"
        if force_deep:
            actor = event["sender"]["login"]
            permission = github.call(f"/collaborators/{quote(actor, safe='')}/permission")["permission"]
            if permission not in ("admin", "maintain", "write"):
                raise ReviewUnavailable("Deep review requires maintainer permission")
        diff_base = github.comparison_base(base, head)
        alive()
        state.admit(number)
        key = env.get("OPENROUTER_API_KEY")
        if not key:
            raise ReviewUnavailable("Review key missing")
        # A large PR can take time to collect. Acknowledge it and archive prior
        # advice before those reads, rather than leaving the author waiting.
        checkpoint(snapshot)
        files = github.files(current["changed_files"])
        alive()
        files = complete_files(github, files, diff_base, head)
        context = ThreatContext((root / "docs/threat-model.yaml").read_text())
        paid = paid_factory(state, number, run_id, key, context.prefix(), alive=alive)
        scanner = Scanner(context, files, state, paid, checkpoint, base)
        evidence = scanner.evidence
        checkpoint(scanner.snapshot())
        snapshot = scanner.run(force_deep)
    except Exception as error:
        snapshot = scanner.snapshot() if scanner else snapshot
        snapshot.setdefault("errors", []).append(failure(error))
        try:
            checkpoint(snapshot)
        except Exception:
            # Preserve local evidence in Actions when durable storage is down.
            # Never start another paid call after any failed checkpoint.
            try:
                publish()
            except Exception:
                # Delivery can fail or become stale; return the saved report
                # to the Actions summary rather than losing local findings.
                pass
    return status_body(repository, head, base, diff_base, snapshot, evidence, history)
