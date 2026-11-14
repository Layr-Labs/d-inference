### A looping thought's answer is no longer refused on a full Mac

- When the loop guard ends a thought, the answer's continuation now takes the stopped request's place in the Mac's serving allowance. On a full Mac, work waiting for a slot took that place first and the continuation was refused, ending `length` with no answer: 2 of 7 Gemma exits on a Mac A GPU check at 16-on-8 concurrency. Other requests still wait for a free place. `DARKBLOOM_LOOP_EXIT_THINKING=0` still turns the exit off.
- Under memory pressure the engine evicts an ordinary running request before a continuation (that request recomputes its work so far).
