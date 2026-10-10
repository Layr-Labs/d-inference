#!/usr/bin/env python3
"""Compare a staged reference's greedy tokens with the product's completion for
the same user text. The product returns text; it is tokenized with the
artifact's own tokenizer and compared token by token with the reference.
usage: product_compare.py TOKENIZER.json PRODUCT.json TEXT_FILE_NAME REFERENCE.json"""
import json, sys
from tokenizers import Tokenizer
tok = Tokenizer.from_file(sys.argv[1])
product = next(r for r in json.load(open(sys.argv[2]))["requests"] if r["text_file"] == sys.argv[3])
ref = json.load(open(sys.argv[4])); ev = ref["evidence"]; ids = ev["selectedTokenIDs"]; stops = set(ref["identity"]["stopTokenIDs"])
ref_ids = ids[:-1] if ids and ids[-1] in stops else ids
prod_ids = tok.encode(product["content"], add_special_tokens=False).ids
usage = product["usage"] or {}
out = {"text_file": sys.argv[3], "product_prompt_tokens": usage.get("prompt_tokens"),
       "reference_prompt_tokens": ref["identity"]["promptTokenCount"],
       "product_completion_tokens": usage.get("completion_tokens"), "reference_selected_tokens": len(ids),
       "reference_finish": ev["finishReason"], "product_finish": product["finish_reason"],
       "product_text_tokens": len(prod_ids), "reference_tokens_before_stop": len(ref_ids)}
n = min(len(prod_ids), len(ref_ids)); first = next((i for i in range(n) if prod_ids[i] != ref_ids[i]), None)
out["compared_tokens"] = n; out["first_difference"] = first
out["tokens_equal"] = first is None and len(prod_ids) == len(ref_ids)
out["product_text_decodes_to_reference_text"] = tok.decode(ref_ids, skip_special_tokens=False) == product["content"]
if first is not None:
    step = ev["steps"][first]
    out["at_difference"] = {"reference_token": ref_ids[first], "product_token": prod_ids[first],
        "reference_top_tokens": step["topTokenIDs"], "reference_top_logits": step["topLogits"],
        "margin_top1_top2": step["topLogits"][0] - step["topLogits"][1],
        "product_token_is_reference_runner_up": prod_ids[first] in step["topTokenIDs"][1:2],
        "reference_text": tok.decode(ref_ids[max(0, first - 8):first + 4]), "product_text": tok.decode(prod_ids[max(0, first - 8):first + 4])}
elif len(prod_ids) != len(ref_ids):
    out["length_note"] = "one side has more tokens after the common prefix"
print(json.dumps(out, indent=1))
