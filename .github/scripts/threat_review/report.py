"""Render fixed-format advisory comments; model output cannot create mentions/HTML."""
import re
import html
from urllib.parse import quote

MARKER = "<!-- threat-model-review:openrouter:v1 -->"


def plain(value):
    value = html.escape(value, quote=False)
    value = value.replace("@", "@\u200b").replace("\r", " ").replace("\n", " ")
    return re.sub(r"([\\`*_{}\[\]()#+.!|<>~-])", r"\\\1", value)


def render(repository, head, base, model, findings, evidence, limits, error=None):
    root = f"https://github.com/{repository}"
    lines = [MARKER, "## Threat model review — advisory", "",
             f"Reviewed head [`{head[:12]}`]({root}/commit/{head}) against base `{base[:12]}`.", ""]
    if error:
        lines += ["**Review not completed for this head.** Previous findings are superseded, not confirmed resolved.",
                  plain(error)]
    elif findings:
        for finding in findings:
            path = finding["file"]
            sha = head if finding["side"] == "head" else base
            linked_path = path if finding["side"] == "head" else evidence[path]["base_path"]
            url = f"{root}/blob/{sha}/{quote(linked_path, safe='/')}#L{finding['line']}"
            refs = ", ".join(finding["threat_ids"]) or "new attack surface"
            lines += [f"### {finding['severity'].upper()}: {plain(finding['title'])}",
                      f"[{plain(path)}:{finding['line']}]({url}) · {refs}", "",
                      plain(finding["detail"]), ""]
    else:
        lines += ["No actionable findings in the reviewed text. This is not a security approval."]
    if limits:
        lines += ["", f"**Coverage limited:** {len(limits)} file(s) had missing or truncated patches."]
    lines += ["", f"Model: {plain(model)}. Findings require human validation; this review never requests changes or blocks merging."]
    return "\n".join(lines)
