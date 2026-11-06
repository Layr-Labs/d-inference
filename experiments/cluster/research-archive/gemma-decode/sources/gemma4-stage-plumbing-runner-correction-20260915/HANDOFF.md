# Gemma Foundation runner correction

The original 8317c322 source freeze is unchanged, including all eight proposed Runtime files and six Swift fixtures. Only the launcher is replaced for execution.

The original runner could kill a process group after reaping its direct child, allowing a reused group ID to be signalled. This correction reuses the byte-exact `owned_process.py` from `qwen27b-resident-load-diagnostics-build-20260915`. That helper authorizes destructive cleanup only from the still-unreaped Popen state, before any cleanup poll/wait. Post-reap group presence is an observation and a failed proof, never kill authorization. The corrected wrapper performs no signals or waits of its own.

The helper's one-line launch observation is redirected to an in-memory StringIO, so a closed parent output pipe cannot interrupt the helper between launch and its cleanup try block. The receipt retains the successful launch line. Compiler and fixture output still go to fresh local files.

The wrapper validates its two files from runner-inputs.json and all original compilation/input pins before and after each stage. The original compile60s/jobs2 and fixture10s bounds, private module cache and Swift assertions are unchanged. Source AST was parsed; no compiler or child execution has occurred for this correction. The reused helper's previous execution evidence remains attributed to its original package.

After explicit root compiler grant:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/gemma4-stage-plumbing-runner-correction-20260915/run.py --output /Users/developer/DarkbloomDev/cluster-research/gemma4-stage-plumbing-checks-1-20260915
```
