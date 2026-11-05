### MiMo-V2.6-Flash tensor parallel reads its weights in seconds instead of over an hour

- Each Mac's half of MiMo's expert weights was read about 100 million small pieces at a time, so a tensor-parallel load could not finish before its startup deadline: both Macs showed "Loading" until "this Mac's part ended (exit 1: deadline)". The pieces of a row that share disk pages are now read together, with the same bytes and the same memory limit for the read.
