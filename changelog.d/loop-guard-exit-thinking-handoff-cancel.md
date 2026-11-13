### A local client that leaves while a looping thought is being ended no longer starts the answer

- On the scheduler's text path (Gemma 4 by default; the Qwen model types when listed in `DARKBLOOM_LOOP_EXIT_THINKING`): when the loop guard ends a thought and a local API client disconnects while the stopped row is still releasing its slot (up to 5 s), the provider no longer submits the answer's continuation only to cancel it at once. The request ends as `length`, as before, with no second prefill. Nemotron 3.5 Super's route already behaved this way.
