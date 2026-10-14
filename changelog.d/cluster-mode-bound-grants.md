### Pair-serving grants bound to the mode their records ran

- A qualification record now grants only its own mode family (pipeline variants, pipeline with speculative rounds, tensor parallel, or the off-by-default hand-off modes) and only the chip classes in the roles it ran; a phase-split pass no longer opens pipeline or tensor-parallel placements. A diverged record withholds its own family; an inconclusive one neither grants nor withholds. The planner keeps to the same rule, and a start checked without its mode is refused.
