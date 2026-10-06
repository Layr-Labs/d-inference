"""Independent full reviews, attributed union, and explicit per-model failures."""
import json
import re
from .client import ReviewUnavailable, ScanTimeout
from .review import DEFAULT_MODEL, FindingCapacityReached, prepare, review

DEFAULT_MODELS = (DEFAULT_MODEL, "openai/gpt-6-astra")


def configured_models(env):
    value = env.get("THREAT_REVIEW_MODELS") or env.get("THREAT_REVIEW_MODEL")
    models = [part.strip() for part in value.split(",")] if value else list(DEFAULT_MODELS)
    if (not 1 <= len(models) <= 2 or len(set(models)) != len(models)
            or any(not re.fullmatch(r"[A-Za-z0-9_.:/-]{1,150}", model) for model in models)):
        raise ReviewUnavailable("Configure one or two distinct model identifiers")
    return models


def review_models(threat_model, files, key, models, reviewer=review):
    _, evidence, limits = prepare(threat_model, files)
    unique, outcomes = {}, []
    for index, model in enumerate(models):
        status = "completed"
        try:
            findings, _, _ = reviewer(threat_model, files, key, model)
        except FindingCapacityReached as error:
            findings = error.findings
            status = "incomplete (finding capacity reached)"
        except ScanTimeout:
            # Preserve completed reviewers even when the global deadline expires.
            outcomes.extend({"model": pending, "status": "incomplete (runtime limit)"}
                            for pending in models[index:])
            break
        except Exception:
            # Never expose exception text: it can contain prompts or credentials.
            outcomes.append({"model": model, "status": "incomplete (review unavailable)"})
            continue
        outcomes.append({"model": model, "status": status})
        for finding in findings:
            canonical = dict(finding, threat_ids=sorted(set(finding["threat_ids"])))
            identity = json.dumps(canonical, sort_keys=True)
            if identity not in unique:
                unique[identity] = dict(canonical, models=[])
            unique[identity]["models"].append(model)
    # Exact duplicate reports share attribution. Differing assessments are kept;
    # a clean reviewer never vetoes another reviewer's evidence-backed finding.
    return list(unique.values()), evidence, limits, outcomes
