### A slow MiMo step no longer stops the MiMo slot for good

- Before, a native MiMo step that ran longer than 30 s, such as a prefill step deep into a long prompt on an M3 Ultra, made the engine's step watchdog seal the engine. The engine never took another step, even after the slow step finished, and the slot stopped serving until MiMo was reloaded.
- Now a native MiMo step may run up to 120 s, the time the engine already allows a prefill to go without progress. A step that never finishes is still caught, after two minutes instead of 30 s. Other models keep 30 s.
