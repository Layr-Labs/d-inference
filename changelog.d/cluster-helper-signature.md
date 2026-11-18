### A two-Mac pair starts only helper processes signed like Darkbloom itself (security)

- A signed Darkbloom starts a pair's owner and worker processes only if they carry its own Developer ID signature and their expected identifiers, and the owner only if it is Darkbloom's own executable. It checks the file before starting it and the started process before writing anything to it; otherwise the pair is not served, and `darkbloom cluster doctor` names the helper to reinstall.
