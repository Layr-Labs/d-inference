#include "Fixture.h"

void meshPointToPoint() {
  fixture::MeshPair pair;
  const int64_t maximum = FRAME_SIZE * (1 << (BUFFER_SIZES - 1));
  for (int64_t count : {int64_t(1), int64_t(24), int64_t(4096), int64_t(17),
      int64_t(4097), maximum * 3 + 17}) {
    pair.fabric.frames.clear();
    std::vector<char> input(count, 0x53), output(count + 1, 0x29);
    fixture::both([&] { pair.nodes[0]->send(input.data(), count, 1); },
        [&] { pair.nodes[1]->recv(output.data(), count, 0); });
    fixture::require(std::equal(input.begin(), input.end(), output.begin())
        && output.back() == 0x29, "Mesh receive changed payload or wrote past end");
    pair.fabric.requireDrained();
    fixture::payloadFrames(fixture::selected(pair.fabric, 0, 0, 0), input);
  }
}

void ringPointToPoint() {
  const int64_t maximum = FRAME_SIZE * (1 << (BUFFER_SIZES - 1));
  for (int wires : {1, 2}) {
    fixture::RingPair pair(wires);
    for (int64_t count : {int64_t(1), int64_t(4096), int64_t(17), maximum * 3 * wires + 13}) {
      pair.fabric.frames.clear();
      std::vector<char> input(count, 0x64), output(count + 1, 0x29);
      fixture::both([&] { pair.nodes[0]->send(input.data(), count, 1, wires); },
          [&] { pair.nodes[1]->recv(output.data(), count, 0, wires); });
      fixture::require(std::equal(input.begin(), input.end(), output.begin())
          && output.back() == 0x29, "Ring receive changed payload or wrote past end");
      pair.fabric.requireDrained();
      const size_t perWire = (count + wires - 1) / wires;
      for (int wire = 0; wire < wires; ++wire) {
        const size_t start = std::min(size_t(count), wire * perWire);
        const size_t end = std::min(size_t(count), (wire + 1) * perWire);
        auto frames = fixture::selected(pair.fabric, 0, 1, wire);
        fixture::payloadFrames(frames, std::span<const char>(input).subspan(start, end - start));
      }
    }
  }
}
