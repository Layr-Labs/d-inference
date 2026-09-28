"""Render fixed-format advisory comments; model output cannot create mentions/HTML."""
import re
import html
from urllib.parse import quote

MARKER = "<!-- threat-model-review:openrouter:v1 -->"
LEGACY_MARKER = "<!-- threat-model-review -->"


def plain(value):
    value = html.escape(value, quote=False)
    value = value.replace("@", "@\u200b").replace("\r", " ").replace("\n", " ")
    return re.sub(r"([\\`*_{}\[\]()#+.!|<>~-])", r"\\\1", value)


def render(repository, head, base, model, findings, evidence, limits, error=None, diff_base=None, outcomes=()):
    root = f"https://github.com/{repository}"
    lines = [MARKER, "## Threat model review — advisory", "",
             f"Reviewed head [`{head[:12]}`]({root}/commit/{head}) against base `{base[:12]}`.", ""]
    if error:
        lines += ["**Review not completed for this head.** Previous findings are superseded, not confirmed resolved.",
                  plain(error)]
    if outcomes:
        lines += ["", "Reviewers: " + "; ".join(
            f"{plain(item['model'])}: {plain(item['status'])}" for item in outcomes), ""]
    if findings:
        for finding in findings:
            path = finding["file"]
            sha = head if finding["side"] == "head" else (diff_base or base)
            linked_path = path if finding["side"] == "head" else evidence[path]["base_path"]
            url = f"{root}/blob/{sha}/{quote(linked_path, safe='/')}"
            if finding["line"]:
                url += f"#L{finding['line']}"
                location = f":{finding['line']}"
            else:
                location = " (file metadata)"
            refs = ", ".join(finding["threat_ids"]) or "new attack surface"
            lines += [f"### {finding['severity'].upper()}: {plain(finding['title'])}",
                      f"[{plain(path)}{location}]({url}) · {refs}", "",
                      plain(finding["detail"]), ""]
            if finding.get("models"):
                lines += ["Raised by: " + ", ".join(plain(name) for name in finding["models"]), ""]
    elif not error and not limits:
        lines += ["No actionable findings in the reviewed text. This is not a security approval."]
    if limits:
        lines += ["", f"**Scan incomplete:** {len(limits)} file(s) could not be fully read as text. Binary/submodule changes require manual review."]
        lines += ["Affected files: " + ", ".join(plain(path) for path in limits)]
    elif not error:
        lines += ["", f"Coverage: {len(evidence)} changed file(s), complete before/after text, and a cross-file threat-model review."]
    lines += ["", f"Models: {plain(model)}. Findings require human validation; this review never requests changes or blocks merging."]
    return "\n".join(lines)
