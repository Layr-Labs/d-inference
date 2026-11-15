#!/usr/bin/env python3
"""Write fixtures/prompt-contract/v1/reasoning_effort_vectors.json.

The provider's reasoning-effort tables (ReasoningEffort.swift) as shared cases:
for each model family the provider serves, each effort a client names (as
reasoning_effort, reasoning.effort and, for GLM-5.3-Flash,
chat_template_kwargs.reasoning_effort) and what the model's template receives,
or the field refused as an effort that is none of the names.

The file is the contract with the coordinator, and it is generated, never
edited by hand: this script restates the Swift tables, and running it again
must leave the file unchanged. CachePromptParityTests.reasoningEffortVectors
checks every case against the production prompt pipeline. darkbloom-platform
copies the file byte for byte from a reviewed commit, and checks its ingress
refusal, first-party pool and prompt sidecar against it.

`context` lists the template-context keys a case decides: a value must be
equal, null must be absent; other keys are not compared. `refused` names the
field of an effort refused as none of the names (the local API's
invalid_reasoning_effort `param`); `error` marks a request refused otherwise
(contradictory spellings).

The file also lists each set the table keeps: the model types that reason, the
Qwen 3.5 template family's types, the types whose effort sets a thinking
switch, and the concrete Qwen 3.8 builds. Every copy that keeps a set checks it
for equality, and every type that reasons has cases, so a type or a build added
or dropped on one side only fails a test on the other.

A new family that reasons adds its model types to these sets, here and in
ReasoningEffort.swift, a Family below (and a variant for each other type it
serves), and the regenerated file, with the case count CachePromptParityTests
pins.

Usage: scripts/generate-reasoning-effort-vectors.py [OUTPUT]
(default: the fixture above, in this repository).
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

NAMES = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

# ReasoningEffortPolicy.reasoningModelTypes: an effort that is none of the
# names is refused for these types; any other type ignores the effort.
REASONING_MODEL_TYPES = [
    "qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35", "qwen4_exp", "qwen4_exp_text",
    "gemma4", "gemma4_text", "gemma4_vision", "diffusion_gemma", "gpt_oss",
    "nemotron_h", "nemotron_h_omni", "mimo_v2", "glm5_next", "glm5_next_text", "glm5_next_mtp", "flint",
    "muse_glimmer",
]

# ReasoningEffortPolicy.qwen35TemplateTypes: the Qwen 3.5 template family,
# which takes Qwen 3.8's levels while thinking.
QWEN35_TEMPLATE_MODEL_TYPES = ["qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35"]

# ReasoningEffortPolicy.effortSwitchTypes: Gemma 4 and DiffusionGemma, whose
# effort sets their thinking switch (ReasoningEffort.oneDepthThinking).
THINKING_SWITCH_MODEL_TYPES = ["gemma4", "gemma4_text", "gemma4_vision", "diffusion_gemma"]

# ModelRuntimeRequirements.qwen38ConcreteModelIDs: Qwen 3.8 builds, which take
# Qwen 3.8's levels and reason whatever their type.
QWEN38_MODEL_IDS = ["EigenLabs/Qwen3.8-27B-4bit", "EigenLabs/Qwen3.8-27B-4bit-mtp"]

QWEN38_LEVELS = ["low", "medium", "xhigh"]
HARMONY_LEVELS = ["low", "medium", "high"]
GLM_LEVELS = ["low", "high", "max"]
SUPER_LEVELS = ["medium", "high"]
GLIMMER_LEVELS = ["low", "medium", "high", "xhigh"]

# The field whose effort a template reads when a request names several: the
# typed reasoning.effort, then reasoning_effort, then GLM-5.3-Flash's own.
PRECEDENCE = ["reasoning.effort", "reasoning_effort", "chat_template_kwargs.reasoning_effort"]

# The spellings each family is asked: every name in both fields, other
# spellings of a name, an effort that is none of the names, and both fields.
# "HİGH" (U+0130) is no name: full Unicode lower-casing gives "hi̇gh".
SINGLE_VALUES = NAMES + [" High ", "OFF", "0", "off", "HİGH", "turbo"]
PAIRS = [("turbo", "low"), ("low", "turbo"), ("high", "HIGH")]


def client_value(value: str) -> str | None:
    """ReasoningEffort(clientValue:): trimmed, any case; off and 0 mean none."""
    name = value.strip().lower()
    if name in ("off", "0"):
        return "none"
    return name if name in NAMES else None


def exact_value(value: str) -> str | None:
    """ReasoningEffort(rawValue:): the names exactly as written."""
    return value if value in NAMES else None


def level(effort: str, levels: list[str]) -> str:
    """The rule every family table in ReasoningEffort.swift follows: the effort's
    own level, else the next one up, else the highest."""
    rank = NAMES.index(effort)
    return next((each for each in levels if NAMES.index(each) >= rank), levels[-1])


def as_sent(field: str, value: str) -> str:
    """The effort a generic template context receives: reasoning.effort as sent,
    reasoning_effort trimmed (ChatTemplateControls)."""
    return value if field == "reasoning.effort" else value.strip()


def body_controls(top: str | None = None, nested: str | None = None, kwargs: str | None = None) -> dict:
    controls: dict = {}
    if top is not None:
        controls["reasoning_effort"] = top
    if nested is not None:
        controls["reasoning"] = {"effort": nested}
    if kwargs is not None:
        controls["chat_template_kwargs"] = {"reasoning_effort": kwargs}
    return controls


class Family:
    """One family's reading of the effort fields and the context it renders."""

    name: str
    model: str
    model_type: str
    # The spellings it is asked (a variant is asked fewer, and no pairs).
    values = SINGLE_VALUES
    pairs = PAIRS
    exact = False
    # Which fields are checked for an effort that is none of the names: the
    # winning one only (generic and Super), or each supplied one in this order.
    checks_every_field = False
    field_order = ["reasoning_effort", "reasoning.effort"]

    def read(self, value: str) -> str | None:
        return exact_value(value) if self.exact else client_value(value)

    def outcome(self, fields: dict[str, str]) -> dict:
        winner = next(field for field in PRECEDENCE if field in fields)
        checked = [field for field in self.field_order if field in fields] if self.checks_every_field else [winner]
        for field in checked:
            if self.read(fields[field]) is None:
                return {"refused": field}
        if self.conflict(fields):
            return {"error": True}
        return {"context": self.context(winner, fields[winner], self.read(fields[winner]))}

    def conflict(self, fields: dict[str, str]) -> bool:
        return False

    def context(self, field: str, value: str, effort: str) -> dict:
        raise NotImplementedError


class QwenFamily(Family):
    """The Qwen 3.5 template family and the owned Flash-Next build: Qwen 3.8's
    low, medium and xhigh while thinking (ReasoningEffort.qwen38Level)."""

    def __init__(self, name: str, model: str, model_type: str):
        self.name, self.model, self.model_type = name, model, model_type

    def context(self, field, value, effort):
        if effort == "none":
            return {"enable_thinking": False, "reasoning_effort": as_sent(field, value)}
        return {"enable_thinking": None, "reasoning_effort": level(effort, QWEN38_LEVELS)}


class Gemma4(Family):
    """A thinking switch and no effort level: none switches thinking off, every
    other effort switches it on (ReasoningEffort.oneDepthThinking)."""

    name, model, model_type = "gemma4", "gemma-4-26b-qat-4bit", "gemma4"

    def context(self, field, value, effort):
        return {"enable_thinking": effort != "none", "reasoning_effort": as_sent(field, value)}


class DiffusionGemma(Gemma4):
    """DiffusionGemmaReasoningControl: every effort but none thinks."""

    name, model, model_type = "diffusion_gemma", "native-diffusion", "diffusion_gemma"


class Lightning(Family):
    """Nemotron 3.5 Lightning: none switches thinking off; any other effort keeps
    the template's default (on)."""

    name, model, model_type = "nemotron_h", "EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp", "nemotron_h"

    def context(self, field, value, effort):
        return {"enable_thinking": False if effort == "none" else None, "reasoning_effort": as_sent(field, value)}


class Harmony(Family):
    """GPT-OSS: Harmony's low, medium and high; reasoning can't be switched off,
    so none selects low (ReasoningEffort.harmonyLevel)."""

    name, model, model_type = "gpt_oss", "gpt-oss-20b", "gpt_oss"

    def context(self, field, value, effort):
        return {"enable_thinking": False if effort == "none" else None,
                "reasoning_effort": level(effort, HARMONY_LEVELS)}


class MiMo(Family):
    """MiMo V2.6: one depth; every effort but none thinks. Every supplied effort
    is checked, reasoning_effort first (MiMoV26TemplateFix,
    ReasoningEffort.oneDepthThinking)."""

    name, model, model_type = "mimo_v2", "mimo-v2.6-flash-mopd", "mimo_v2"
    checks_every_field = True

    def context(self, field, value, effort):
        return {"enable_thinking": effort != "none"}


class Super(Family):
    """Nemotron 3.5 Super: medium_effort for minimal, low and medium, the
    default depth for high, xhigh and max; spellings that differ are refused
    (NemotronSuperPromptContract.controls, ReasoningEffort.nemotronSuperMediumEffort)."""

    name, model, model_type = "nemotron_h_omni", "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4", "nemotron_h_omni"

    def conflict(self, fields):
        if "reasoning_effort" in fields and "reasoning.effort" in fields:
            return fields["reasoning_effort"].strip().lower() != fields["reasoning.effort"].strip().lower()
        return False

    def context(self, field, value, effort):
        if effort == "none":
            return {"enable_thinking": False, "medium_effort": False}
        return {"enable_thinking": True, "medium_effort": level(effort, SUPER_LEVELS) == "medium"}


class GLM(Family):
    """GLM-5.3-Flash: low, high and max (max with no effort); none and off switch
    thinking off; the names exactly as written, each supplied alias checked
    (GLM5NextPromptPolicy, ReasoningEffort.glmLevel)."""

    name, model, model_type = "glm5_next", "glm-5.3-flash", "glm5_next"
    exact = True
    checks_every_field = True
    field_order = ["reasoning_effort", "reasoning.effort", "chat_template_kwargs.reasoning_effort"]

    def read(self, value):
        return "none" if value in ("none", "off") else exact_value(value)

    def context(self, field, value, effort):
        if effort == "none":
            return {"enable_thinking": False, "reasoning_effort": "max"}
        return {"enable_thinking": None, "reasoning_effort": level(effort, GLM_LEVELS)}


class Flint(Family):
    """Flint decides whether to reason: every name is taken, exactly as written,
    with no effect (FlintRequestPolicy)."""

    name, model, model_type = "flint", "RecursiveSI/flint-int4", "flint"
    exact = True
    checks_every_field = True

    def context(self, field, value, effort):
        return {}


class Glimmer(Family):
    """Muse Glimmer: its template's reasoning_strength, low, medium, high (with no
    effort) or xhigh; it has no thinking switch, so none selects low
    (MuseGlimmerRequestPolicy, ReasoningEffort.museGlimmerStrength)."""

    name, model, model_type = "muse_glimmer", "muse-glimmer-30b", "muse_glimmer"

    def context(self, field, value, effort):
        return {"reasoning_strength": level(effort, GLIMMER_LEVELS)}


class NoReasoning(Family):
    """A model that doesn't reason ignores any effort, a name or not."""

    name, model, model_type = "llama", "org/llama", "llama"

    def read(self, value):
        return client_value(value) or value

    def context(self, field, value, effort):
        return {"enable_thinking": False if effort == "none" else None, "reasoning_effort": as_sent(field, value)}


FAMILIES: list[Family] = [
    QwenFamily("qwen3_5", "EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5"),
    QwenFamily("qwen3_5_moe", "qwen3.5-35b-a3b", "qwen3_5_moe"),
    QwenFamily("prism_hadamard_qwen35", "ternary-bonsai-2-27b", "prism_hadamard_qwen35"),
    QwenFamily("qwen4_exp", "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp", "qwen4_exp"),
    Gemma4(), DiffusionGemma(), Lightning(), Harmony(), MiMo(), Super(), GLM(), Flint(), Glimmer(),
    NoReasoning(),
]

# Each other type that reasons is asked fewer spellings, enough to tell its
# family's reading from another's: none, a name, a padded and a capitalised
# spelling, a non-ASCII one and one that is none of the names.
VARIANT_VALUES = ["none", "max", " High ", "OFF", "HİGH", "turbo"]


def variant(of: str, model: str, model_type: str) -> Family:
    """The reading of the family of type `of`, under another type it serves."""
    other = copy.copy(next(family for family in FAMILIES if family.model_type == of))
    other.name, other.model, other.model_type = model_type, model, model_type
    other.values, other.pairs = VARIANT_VALUES, []
    return other


VARIANTS: list[Family] = [
    variant("qwen4_exp", "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp", "qwen4_exp_text"),
    variant("gemma4", "gemma-4-26b-text", "gemma4_text"),
    variant("gemma4", "gemma-4-vision", "gemma4_vision"),
    variant("glm5_next", "glm-5.3-flash", "glm5_next_text"),
    variant("glm5_next", "glm-5.3-flash", "glm5_next_mtp"),
]


def cases_for(family: Family) -> list[dict]:
    asked: list[dict[str, str]] = []
    for value in family.values:
        asked.append({"reasoning_effort": value})
        asked.append({"reasoning.effort": value})
    for top, nested in family.pairs:
        asked.append({"reasoning_effort": top, "reasoning.effort": nested})
    if isinstance(family, GLM):
        asked += [{"chat_template_kwargs.reasoning_effort": value} for value in ["xhigh", "Low", "turbo"]]
    cases = []
    for fields in asked:
        label = "+".join(f"{field}={value.strip() or repr(value)}" for field, value in fields.items())
        controls = body_controls(fields.get("reasoning_effort"), fields.get("reasoning.effort"),
                                 fields.get("chat_template_kwargs.reasoning_effort"))
        case = {"name": f"{family.name}/{label}", "model": family.model, "model_type": family.model_type,
                "controls": controls}
        case.update(family.outcome(fields))
        cases.append(case)
    return cases


def document() -> dict:
    cases = [case for family in FAMILIES + VARIANTS for case in cases_for(family)]
    names = {case["name"] for case in cases}
    assert len(names) == len(cases), "case names are unique"
    asked = {case["model_type"] for case in cases}
    assert set(REASONING_MODEL_TYPES) <= asked, f"every type that reasons has cases: {set(REASONING_MODEL_TYPES) - asked}"
    return {
        "schema": "darkbloom-reasoning-effort-vectors-v1",
        "efforts": NAMES,
        "refusal": {
            "code": "invalid_reasoning_effort",
            "type": "invalid_request_error",
            "message": "{param} must be one of: " + ", ".join(NAMES) + ".",
        },
        "reasoning_model_types": REASONING_MODEL_TYPES,
        "qwen35_template_model_types": QWEN35_TEMPLATE_MODEL_TYPES,
        "thinking_switch_model_types": THINKING_SWITCH_MODEL_TYPES,
        "qwen38_model_ids": QWEN38_MODEL_IDS,
        "cases": cases,
    }


def main() -> int:
    default = Path(__file__).resolve().parent.parent / "fixtures/prompt-contract/v1/reasoning_effort_vectors.json"
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    vectors = document()
    output.write_text(json.dumps(vectors, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{output}: {len(vectors['cases'])} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
