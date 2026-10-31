### Fixed

- Automatic cluster planning considers tensor-parallel placements independently
  of pipeline layer cuts and counts enumerated candidates instead of unused
  pipeline-cut combinations against its search limit. Unsupported runtime modes and rank counts now explain the pipeline
  fallback before requesting a link measurement, without claiming an unmeasured
  speedup. This does not enable tensor parallelism for GLM.
