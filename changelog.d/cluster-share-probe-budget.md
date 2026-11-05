### A slow Mac's tensor-parallel share probe is no longer skipped

- A tensor-parallel load's share probe (Qwen and Gemma) now counts its 1.5 s budget from the first timed round, after the throwaway request's set-up, prompt and warm-ups. Before, a Mac whose warm-ups were slow (first-use kernel compiles, a GPU the desktop shares) gave no probe at all: pair-2's M3 Ultra logged `skipped=budget` on every load, so the planner never had its measured share step and could not weight the split or choose tensor parallel on evidence for it.
