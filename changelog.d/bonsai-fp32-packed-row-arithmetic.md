### Bonsai 27B packed FP32 row arithmetic

Bonsai 27B now preserves the singleton FP32 packed projection reduction for each prefill row, avoiding architecture-dependent TF32 matrix arithmetic in its signed-Hadamard layers. Its exact arithmetic receipt changes so mixed old/new ranks refuse to load together; Bonsai 9B and other model arithmetic are unchanged.
