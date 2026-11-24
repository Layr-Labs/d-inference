### Startup calibration no longer waits for the next capacity tick

After the startup self-test, a native engine's stream could end before the
engine released the request's hold on the Mac. Calibration starts only on an
idle Mac, so the end of the startup preload sometimes found it busy and left
calibration to the next capacity tick. The self-test now returns once the
request is released (at most 2 s), so calibration starts right after the
preload.
