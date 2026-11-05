### MiMo-V2.6-Flash tensor parallel now loads in time

- Each Mac read its half of MiMo's expert weights in about 100 million tiny pieces, which took over an hour, so the load always ran out of time and both Macs showed "Loading" until "this Mac's part ended (exit 1: deadline)". The pieces that sit next to each other on disk are now read together, which takes seconds. The bytes loaded, and the memory used to read them, are unchanged.
