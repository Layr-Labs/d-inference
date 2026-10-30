### SSD cache reads skip a copy of each encrypted chunk

- Reading an SSD cache file keeps each encrypted chunk in the buffer it was
  read into instead of copying it into a second one, when one read returns the
  whole chunk, as it usually does from a local file. Reading and decrypting a
  512 MiB file of 4 MiB chunks from a warm page cache took a median 136 ms
  instead of 146 ms on an M3 Ultra (debug build), and a chunk occupies one
  buffer instead of two while it is read.
