"""Validate prepared suite files and the input identity reported by a child."""
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_hash(value):
    if (not isinstance(value, str) or len(value) != 64
            or any(c not in "0123456789abcdef" for c in value)):
        raise RuntimeError("Invalid prepared input SHA-256")
    return value


class PreparedSuite:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.path = self.directory / "suite.json"
        self.digest = sha(self.path)
        self.document = json.loads(self.path.read_text())

    def checked_file(self, name, expected):
        if not isinstance(name, str) or Path(name).name != name:
            raise RuntimeError("Prepared input file must be a local filename")
        path = self.directory / name
        if not path.resolve().is_relative_to(self.directory.resolve()):
            raise RuntimeError("Prepared input file escapes its suite")
        if sha(path) != require_hash(expected):
            raise RuntimeError("Prepared input changed: " + str(path))
        return path

    def select(self, model, mode):
        if sha(self.path) != self.digest:
            raise RuntimeError("Prepared suite changed: " + str(self.path))
        scores = [item for item in self.document["scoreInputs"] if item["modelID"] == model]
        if len(scores) != 1:
            raise RuntimeError("Missing or ambiguous prepared score input: " + model)
        score = scores[0]
        score_path = self.checked_file(score["file"], score["inputSHA256"])
        score_document = json.loads(score_path.read_text())
        if score_document["modelID"] != model:
            raise RuntimeError("Prepared score model differs: " + model)
        expected_model = require_hash(score_document["expectedModelAggregateSHA256"])
        if (len(score_document["promptTokens"]) != score["promptTokenCount"]
                or len(score_document["continuation"]) != score["continuationTokenCount"]):
            raise RuntimeError("Prepared score token counts differ: " + model)
        identity = {"suiteSHA256": self.digest, "modelID": model, "mode": mode,
                    "expectedModelAggregateSHA256": expected_model,
                    "scoreFile": score["file"], "scoreInputSHA256": score["inputSHA256"]}
        if mode == "scores":
            identity.update(file=score["file"], inputSHA256=score["inputSHA256"])
            return identity, score_path, score_document
        tasks = [item for item in self.document["tasks"] if item["id"] == mode]
        if len(tasks) != 1:
            raise RuntimeError("Missing or ambiguous prepared task: " + mode)
        task = tasks[0]
        prompt = self.checked_file(task["file"], task["promptSHA256"])
        identity.update(file=task["file"], promptSHA256=task["promptSHA256"],
                        renderDate=self.document["renderDate"],
                        maximumGeneratedTokens=task["maximumGeneratedTokens"], expected=task["expected"])
        return identity, prompt, score_document


def validate_report_input(report, mode, identity, score_document, precision):
    if report.get("resolvedBackend") != "paged" or report.get("kvQuantization") != precision:
        raise RuntimeError("Report is not the requested paged precision arm")
    if report.get("verifiedModelAggregateSHA256") != identity["expectedModelAggregateSHA256"]:
        raise RuntimeError("Report model differs from prepared input")
    if mode == "scores":
        if report.get("inputSHA256") != identity["inputSHA256"] or report.get("input") != score_document:
            raise RuntimeError("Report score input differs from prepared input")
    elif (report.get("promptSHA256") != identity["promptSHA256"]
          or report.get("renderDate") != identity["renderDate"]):
        raise RuntimeError("Report prompt/date differs from prepared input")
