### Six-request tensor-parallel batches

- Automatic batching on a two-Mac tensor-parallel pair can now choose six concurrent requests, between four and eight, when eight do not fit. Pipeline batching keeps its widths of two, four and eight.
