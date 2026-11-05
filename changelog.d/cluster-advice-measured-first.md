### The mode question trusts a measured mode over a predicted one

- While one mode has served on the pair and another hasn't, `darkbloom cluster` now recommends the measured mode ("Recommended for Gemma 4 26B on these two Macs: Tensor parallel, the only one measured on these Macs so far.") instead of comparing two predictions. On two M5 Ultras the planner predicted Gemma's pipeline at 152 tokens/s and recommended it over tensor parallel, which had served at 111; the pipeline then served at 64. Through Darkbloom a mode that serves more requests at once still comes first.
