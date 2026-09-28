#include <iostream>
#include <limits>
#include "Fixture.h"
#ifndef EXPECT_ORIGINAL_STALE_TAIL
#include "jaccl/send_frame.h"
#endif

void meshPointToPoint();
void ringPointToPoint();
void meshCollectives();
void ringCollectives();

#ifndef EXPECT_ORIGINAL_STALE_TAIL
void stagingBounds() {
  alignas(double) std::array<char, 32> frame;
  const std::array<uint32_t, 2> input{0x01020304, 0x05060708};
  frame.fill(char(fixture::sentinel));
  jaccl::stage_send_frame(std::span<char>(frame), input.data(), 2);
  fixture::require(std::memcmp(frame.data(), input.data(), 8) == 0, "Typed payload bytes changed");
  fixture::zeroTail({0, 0, 0, std::vector<char>(frame.begin(), frame.end())}, 8);
  jaccl::stage_send_frame(std::span<char>(frame), static_cast<const uint32_t*>(nullptr), 0);
  fixture::zeroTail({0, 0, 0, std::vector<char>(frame.begin(), frame.end())}, 0);
  for (int64_t count : {int64_t(-1), int64_t(9), std::numeric_limits<int64_t>::max()}) {
    frame.fill(char(fixture::sentinel));
    bool refused = false;
    try { jaccl::stage_send_frame(std::span<char>(frame), input.data(), count); }
    catch (const std::invalid_argument&) { refused = true; }
    fixture::require(refused && std::all_of(frame.begin(), frame.end(),
        [](char value) { return static_cast<unsigned char>(value) == fixture::sentinel; }),
        "Invalid count must refuse before any scratch write");
  }
  bool refused = false;
  try { jaccl::stage_send_frame(std::span<char>(frame), static_cast<const char*>(nullptr), 1); }
  catch (const std::invalid_argument&) { refused = true; }
  fixture::require(refused, "Null nonempty source refused");
}
#endif

int main() {
  try {
#ifdef EXPECT_ORIGINAL_STALE_TAIL
    try { meshPointToPoint(); }
    catch (const fixture::StaleTail&) {
      std::cout << "PASS original actual-header sentinel-tail regression reproduced\n";
      return 0;
    }
    throw std::runtime_error("Original native header unexpectedly hid the stale-tail regression");
#else
    stagingBounds(); std::cout << "PASS bounded typed staging and zero-logical frame\n";
    meshPointToPoint(); std::cout << "PASS mesh short/full/reused/multiframe and actual receive\n";
    ringPointToPoint(); std::cout << "PASS ring one/two-wire short/full/reused/multiframe receive\n";
    meshCollectives(); std::cout << "PASS mesh gather/reduce/scatter valid payload and tail\n";
    ringCollectives(); std::cout << "PASS ring reduction/scatter full/partial/zero slices\n";
    std::cout << "PASS actual native headers; fake verbs only; no hardware qualification\n";
    return 0;
#endif
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n'; return 1;
  }
}
