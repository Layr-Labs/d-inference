#!/usr/bin/env python3
"""Text prompts for the product comparison: the instruction, then the passage
repeated as text until the rendered chat prompt is just under a token target.
usage: mk_prompts.py TOKENIZER.json LONG_PASSAGE.txt SHORT_QUESTION.txt OUT_DIR"""
import sys
from pathlib import Path
from tokenizers import Tokenizer
tok = Tokenizer.from_file(sys.argv[1]); long_text = Path(sys.argv[2]).read_text(); out = Path(sys.argv[4])
out.mkdir(parents=True, exist_ok=True)
prefix, suffix = "<bos><|turn>user\n", "<turn|>\n<|turn>model\n<|channel>thought\n<channel|>"
def count(text): return len(tok.encode(prefix + text.strip() + suffix, add_special_tokens=False).ids)
instruction, body = long_text.strip().split("\n\n", 1)
(out / "prod-short.txt").write_text(Path(sys.argv[3]).read_text().strip())
print("prod-short", count(Path(sys.argv[3]).read_text()))
for name, target in (("prod-4k", 4096), ("prod-8k", 8192)):
    words = body.split(); pieces = []; text = instruction
    # Whole words only, so the text renders to the same tokens wherever it is tokenized.
    low, high = 1, 20000
    def make(n): return instruction + "\n\n" + " ".join((words * (n // len(words) + 1))[:n])
    while low < high:
        mid = (low + high + 1) // 2
        if count(make(mid)) <= target: low = mid
        else: high = mid - 1
    text = make(low); (out / f"{name}.txt").write_text(text); print(name, "words", low, "tokens", count(text))
