### Fixed

- Added opt-in `DARKBLOOM_QWEN_ABSORB_STRAY_THINK_CLOSE` for qwen stray thinking-close markers. A complete stray </think> outside a thought is absorbed by native channel splitting. A known closed thought prefix also selects that route for Qwen streams without tools, on text and media paths. Partial markers at end of stream and markers inside tool arguments remain literal. Missing or disabled reasoning parsers do not acquire an inferred thought state. Default-off behavior is unchanged.
