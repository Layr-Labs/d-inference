#include <bit>
#include <cstdio>
#include "jaccl/rdma.h"
static_assert(sizeof(int) == 4);
static_assert(sizeof(jaccl::Destination) == 32);
static_assert(std::endian::native == std::endian::little);
int main() { std::printf("{\"integerBytes\":%zu,\"destinationBytes\":%zu,\"littleEndian\":true}\n", sizeof(int), sizeof(jaccl::Destination)); }
