# Pthread callback signature correction

2026-09-14. V1 is retained unchanged. Root’s Swift 6 compiler aborted in the
SendNonSendable pass before tests; root’s Swift 5 control then reported the
concrete callback mismatch: this SDK imports pthread_create with a nonoptional
UnsafeMutableRawPointer input. V2 changes only that callback parameter and removes
the now-unneeded nil guard. No Sendable annotation, runtime check, ownership rule,
wait/join behavior or gate/API changed. The other three Swift files are identical.

The V1 manifest is 67759b06b74a683cc053926deb19964b12d2b1bd44ebf0c6a9a6c536958fd528.
Its 21-case/four-join source review remains applicable apart from this source-based
ABI correction. Root must compile and execute the four V2 Swift files. This author
has not compiled or run Swift or accessed any native model/candidate.
