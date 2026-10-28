### Model download cancellation

- Fix a hang when a model download is cancelled before its completion waiter is attached. Keep the cancellation result until the waiter can receive it, preserving partial files for a later resume.
