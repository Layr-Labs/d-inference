Metadata-only rebase of frozen bb1d single-refill over actual c721122.
The only predecessor change is Gemma4BenchmarkInput.description; it is preserved.
All four refill output bytes, three exact inverse transforms and eleven staged
controls remain those of the original freeze. Gemma4RemoteMTPInput is a distinct
file and needs no textual rebase. Expected union123. No source materialization,
compiler, native, GPU or remote work performed. Compose snapshot policy through
the original transforms.json and these exact current preimages.
