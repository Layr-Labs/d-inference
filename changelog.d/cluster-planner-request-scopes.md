### Plan explicit cluster requests within each model's actual limits

Cluster planning now handles longer completions and prompts with the registered
family's exact memory charge, including requests whose total tokens fit the
default planning reservation. The native helper and provider share a request
quote bound to the artifact, configuration, request and worker profile. Default
plans, live memory safeguards and GLM exact adapter quotations are unchanged.
