### Child process exit waits

- Report a finished child process without the former polling and run-loop delay. Bounded children (the paged-kernel preflight, update staging, runtime smoke and signature checks, `darkbloom doctor` and `verify` probes) are reported up to about 120 ms sooner each, and waiting for `launchctl`, `codesign`, `profiles`, `open` and `log` no longer runs the calling thread's run loop. Timeouts and the SIGTERM-then-SIGKILL escalation are unchanged.
