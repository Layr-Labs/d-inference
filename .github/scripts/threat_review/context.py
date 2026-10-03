"""Deterministic threat index and relevant verbatim context, without YAML execution."""
import hashlib
import json
import re
from .client import ReviewUnavailable
from .review import ID_DEFINITION, MAX_THREAT_MODEL

VERSION = "budgeted-v2"
SONNET = "anthropic/claude-sonnet-4.6"
OPUS = "anthropic/claude-opus-5.5"
SOL = "openai/gpt-6.1-sol"
RISK = re.compile(r"auth|attest|encrypt|crypt|billing|payment|ledger|mdm|enroll|secret|token|permission|\.github/", re.I)
CRITICAL = re.compile(r"attest|encrypt|crypt|\.github/workflows/", re.I)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


class ThreatContext:
    def __init__(self, text):
        if len(text) > MAX_THREAT_MODEL:
            raise ReviewUnavailable("Threat model exceeds context capacity")
        matches = list(ID_DEFINITION.finditer(text))
        if not matches:
            raise ReviewUnavailable("Threat model has no indexed definitions")
        self.text = text
        self.blocks = []
        for index, match in enumerate(matches):
            end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
            block = text[match.start():end]
            self.blocks.append((match.group(2), block))
        # Include each definition, including duplicate IDs. Explicit excerpts are
        # a routing index, never represented as the full canonical threat text.
        self.index = [{"id": id, "overview_excerpt": block[:300],
                       "detail_chars": len(block)} for id, block in self.blocks]
        self.preamble = text[:matches[0].start()]
        self.hash = digest(text)

    def relevant(self, units, requested=()):
        words = set(re.findall(r"[a-z][a-z0-9_/-]{4,}", json.dumps(units).lower()))
        words -= {"metadata", "modified", "patch", "base_text", "head_text", "false", "return", "string", "status"}
        ranked = sorted(enumerate(self.blocks), key=lambda item: (
            item[1][0] in requested,
            len(words & set(re.findall(r"[a-z][a-z0-9_/-]{4,}", item[1][1].lower()))),
            -item[0]), reverse=True)
        selected, omitted, used = [], [], 0
        for _, (id, block) in ranked[:8]:
            if used + len(block) <= 18_000:
                selected.append({"id": id, "verbatim": block})
                used += len(block)
            else:
                omitted.append(id)
        return {"relevant_definitions": selected, "oversized_definitions": omitted,
                "scope": "All definitions indexed; selected details only. Unchanged callers are not retrieved."}

    def prefix(self):
        return json.dumps({"canonical_context": self.preamble, "all_definition_index": self.index})
