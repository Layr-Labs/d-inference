### A local client that leaves while a looping thought is being ended no longer starts the answer

- When the loop guard ends a thought (Gemma 4 by default; Qwen 3.5/3.6 and Nemotron 3.5 Super when listed in `DARKBLOOM_LOOP_EXIT_THINKING`) and a local API client disconnects while the stopped row is still releasing its slot (up to 5 s), the provider no longer submits the answer's continuation only to cancel it at once: the request ends as `length`, as before, with no second prefill.
