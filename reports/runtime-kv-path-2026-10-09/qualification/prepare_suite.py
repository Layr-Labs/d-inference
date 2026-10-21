#!/usr/bin/env python3
"""Create public synthetic serving tasks and exact token score inputs offline."""
import argparse
import hashlib
import json
import pathlib

from tokenizers import Tokenizer


def digest(data):
    return hashlib.sha256(data).hexdigest()


def ledger(rows, needles):
    lines = []
    for index in range(rows):
        if index in needles:
            lines.append(needles[index])
        else:
            lines.append(
                f"Record {index:04d}: station T{(index * 37) % 997:03d}; "
                f"humidity {(index * 13) % 81 + 10}; color gray; "
                "maintenance routine; observation valid."
            )
    return "\n".join(lines)


def tasks():
    instruction = (
        "Read the reference below. Answer the final question using only a JSON "
        "object, with no explanation. Only named target records matter.\n\n"
    )
    retrieval = {
        3: "TARGET EARLY: release code cedar-0837.",
        87: "TARGET MIDDLE: release code juniper-1942.",
        166: "TARGET LATE: release code hazel-2651.",
    }
    arithmetic = {
        7: "PURCHASE NORA: 4 units at 17 dollars each.",
        92: "PURCHASE ELIO: 3 units at 29 dollars each.",
        151: "PURCHASE MIRA: 2 units at 31 dollars each.",
    }
    program = {
        4: "TARGET PROGRAM:\ndef f(xs):\n    total = 1\n    for x in xs:\n        total += x * x if x % 2 else x // 2\n    return total\nEND PROGRAM",
        105: "TARGET INPUT: [3, 8, 5, 4, 1]",
    }
    distant = {
        5: "TARGET RIVER: owner Leona; access code R73-PINE.",
        344: "TARGET MOUNTAIN: owner Soren; access code M28-ELM.",
        676: "TARGET MEADOW: owner Amara; access code D46-OAK.",
    }
    return [
        ("retrieval", instruction + ledger(175, retrieval) +
            '\n\nReturn the release codes as {"early":...,"middle":...,"late":...}.',
            {"early": "cedar-0837", "middle": "juniper-1942", "late": "hazel-2651"}),
        ("arithmetic", instruction + ledger(175, arithmetic) +
            '\n\nWhat is the combined cost of NORA, ELIO and MIRA? Return {"total":...}.',
            {"total": 217}),
        ("program", instruction + ledger(175, program) +
            '\n\nEvaluate the target Python program on TARGET INPUT. Return {"result":...}.',
            {"result": 42}),
        ("long_retrieval", instruction + ledger(690, distant) +
            '\n\nReturn access codes only as {"river":...,"mountain":...,"meadow":...}.',
            {"river": "R73-PINE", "mountain": "M28-ELM", "meadow": "D46-OAK"}),
    ]


CONTINUATION = """The next morning, the team inspected the river crossing before carrying any equipment over it. The old wooden bridge had been replaced by a broad steel walkway. A yellow sign described the maximum load, and a painted line showed where people should wait. The team divided the instruments into three small groups so that each trip stayed comfortably within the posted limit. Nobody needed to guess whether the crossing was safe.

At the station, Leona checked the thermometer against a second instrument. Both readings agreed within a small margin. She wrote the time, the two values, and the instrument labels in the notebook. Soren then measured the water level from the same marked reference point used the previous day. The surface had fallen slightly overnight, but the rate of flow remained steady. These observations were useful because they could be compared with earlier measurements taken under the same procedure.

After lunch, Amara reviewed the records and found one copied number that did not match the original page. She corrected the copy, kept the original value visible, and added a short note explaining the change. The team completed its summary before sunset. The report separated direct observations from estimates and listed the remaining questions for the following visit. This made it possible for another group to repeat the work without relying on anyone's memory."""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--model-root", type=pathlib.Path, required=True)
    parser.add_argument("--catalog", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    entries = []
    for task, prompt, expected in tasks():
        path = args.output / (task + ".txt")
        path.write_text(prompt)
        entries.append({"id": task, "file": path.name, "promptSHA256": digest(prompt.encode()),
                        "expected": expected, "maximumGeneratedTokens": 1024})
    models = json.loads(args.catalog.read_text())["models"]
    score_inputs = []
    for model in models:
        if "mimo" in model["id"].lower():
            continue
        safe = model["id"].replace("/", "--")
        directory = args.model_root / safe
        if not directory.exists() and model["id"] == "gemma-4-26b":
            directory = args.model_root / "gemma-4-26b-8bit"
        tokenizer = Tokenizer.from_file(str(directory / "tokenizer.json"))
        prefix = ledger(190, {}) + "\n\nField report, continued:\n"
        prompt = tokenizer.encode(prefix, add_special_tokens=False).ids
        continuation = tokenizer.encode(CONTINUATION, add_special_tokens=False).ids[:256]
        document = {"modelID": model["id"], "expectedModelAggregateSHA256": model["aggregate_sha256"],
                    "promptTokens": prompt, "continuation": continuation}
        path = args.output / (safe + "-scores-input.json")
        raw = json.dumps(document, indent=2, sort_keys=True).encode() + b"\n"
        path.write_bytes(raw)
        score_inputs.append({"modelID": model["id"], "file": path.name,
                             "inputSHA256": digest(raw), "promptTokenCount": len(prompt),
                             "continuationTokenCount": len(continuation)})
    manifest = {"schema": 1, "source": "Deterministic public synthetic tasks and original prose; no private requests.",
                "limits": "Four narrow tasks per artifact and one synthetic continuation measure bounded quality drift, not general benchmark accuracy.",
                "renderDate": "2026-10-09", "tasks": entries, "scoreInputs": score_inputs,
                "continuationTextSHA256": digest(CONTINUATION.encode())}
    (args.output / "suite.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"tasks": len(entries), "models": len(score_inputs), "output": str(args.output)}))


if __name__ == "__main__":
    main()
