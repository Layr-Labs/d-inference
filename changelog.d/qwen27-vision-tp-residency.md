

### Qwen27 TP vision residency accounting

Price the registered Qwen3.8 27B vision tower as additional resident TP memory,
using exact per-array inventory and allocator bounds. Native media LOAD
integration is prepared separately and must consume this helper.
The charge remains additive outside request floors and leaves pipeline and
legacy layouts unchanged. Media execution qualification remains separate.
