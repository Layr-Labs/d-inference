### The SSD prefix cache starts over once with a new key

- After the update to this release the SSD prefix cache uses a newly created key and the earlier key is removed. Cached prompt prefixes are rebuilt once, so the first requests after the update may take a little longer to start.
