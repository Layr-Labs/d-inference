### Automatic serving width holds at thermal state fair

- The automatic M5 paged width (8, no reviewed profile) now needs Low Power Mode
  off and a thermal state of nominal or fair; serious and critical still return
  the bridge to the unqualified width (4). A Mac Studio under sustained load sits
  at fair, where the old nominal-only rule held it to 4 requests and kept the
  others waiting for a free row (25-45 s for their first token on an M5 Ultra
  and an M5 Max under sustained serving). Reviewed performance profiles and
  deadline profiles keep the nominal requirement.
