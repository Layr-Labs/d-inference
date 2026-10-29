#include "Fixture.h"

namespace {
std::span<const char> byteView(const std::vector<float>& values, size_t count) {
  return {reinterpret_cast<const char*>(values.data()), count * sizeof(float)};
}
void allEqual(const std::vector<float>& values, size_t count, float expected) {
  fixture::require(std::all_of(values.begin(), values.begin() + count,
      [&](float value) { return value == expected; }), "Collective logical output changed");
  fixture::require(values[count] == -19, "Collective wrote outside logical output");
}
} // namespace

void meshCollectives() {
  const size_t count = (FRAME_SIZE * (1 << (BUFFER_SIZES - 1)) * 3) / sizeof(float) + 7;
  for (int operation : {0, 1, 2}) {
    fixture::MeshPair pair;
    std::array<std::vector<float>, 2> input, output;
    for (int rank = 0; rank < 2; ++rank) {
      input[rank].assign(count * 2, float(rank + 1));
      output[rank].assign(count * 2 + 1, -19);
    }
    auto run = [&](int rank) {
      if (operation == 0) {
        pair.nodes[rank]->all_reduce(input[rank].data(), output[rank].data(), count, fixture::Add{});
      } else if (operation == 1) {
        pair.nodes[rank]->all_gather(reinterpret_cast<const char*>(input[rank].data()),
            reinterpret_cast<char*>(output[rank].data()), count * sizeof(float));
      } else {
        pair.nodes[rank]->sum_scatter(input[rank].data(), output[rank].data(), count, fixture::Add{});
      }
    };
    fixture::both([&] { run(0); }, [&] { run(1); });
    pair.fabric.requireDrained();
    for (int rank = 0; rank < 2; ++rank) {
      if (operation == 1) {
        fixture::require(std::all_of(output[rank].begin(), output[rank].begin() + count,
            [](float value) { return value == 1; }), "Gather rank0 payload changed");
        fixture::require(std::all_of(output[rank].begin() + count, output[rank].begin() + count * 2,
            [](float value) { return value == 2; }) && output[rank].back() == -19,
            "Gather rank1 payload or output bound changed");
      } else { allEqual(output[rank], count, 3); }
      fixture::payloadFrames(fixture::selected(pair.fabric, rank, rank, 0), byteView(input[rank], count));
    }
  }
}

void ringCollectives() {
  // count1 includes zero-logical slices. The long case refills every pipeline
  // slot; real posted capacities are selected by the unmodified native helper.
  const int64_t maximum = FRAME_SIZE * (1 << (BUFFER_SIZES - 1));
  for (bool scatter : {false, true}) {
    for (int64_t chunk : {int64_t(1), maximum * 3 / int64_t(sizeof(float)) * 4 + 7}) {
      const int wires = 2;
      fixture::RingPair pair(wires);
      const int64_t count = scatter ? chunk * 2 : chunk;
      const int64_t stageChunk = scatter ? chunk : (count + 1) / 2;
      const int64_t perWire = (stageChunk + 2 * wires - 1) / (2 * wires);
      const int64_t capacity = buffer_size_from_message(perWire * sizeof(float)).second;
      const int64_t elements = capacity / sizeof(float);
      const int64_t steps = (perWire + elements - 1) / elements;
      std::array<std::vector<float>, 2> input, output;
      for (int rank = 0; rank < 2; ++rank) {
        // Extra storage keeps zero-length inactive source windows valid. It is
        // not part of the logical payload and must never appear in a sent tail.
        input[rank].assign(count + 32, float(rank + 1));
        output[rank].assign((scatter ? chunk : count) + 32, -19);
      }
      auto run = [&](int rank) {
        if (scatter) {
          pair.nodes[rank]->reduce_scatter(input[rank].data(), output[rank].data(), count, wires, fixture::Add{});
        } else {
          pair.nodes[rank]->all_reduce<2>(input[rank].data(), output[rank].data(), count, wires, fixture::Add{});
        }
      };
      fixture::both([&] { run(0); }, [&] { run(1); });
      pair.fabric.requireDrained();
      for (int rank = 0; rank < 2; ++rank) {
        allEqual(output[rank], scatter ? chunk : count, 3);
        for (int direction = 0; direction < 2; ++direction) {
          for (int wire = 0; wire < wires; ++wire) {
            auto frames = fixture::selected(pair.fabric, rank, direction, wire);
            const int passes = scatter ? 1 : 2;
            fixture::require(frames.size() == size_t(steps * passes), "Ring completion/frame count changed");
            const int64_t offset = direction * wires * perWire + wire * perWire;
            const int64_t end = std::min(stageChunk, offset + perWire);
            for (int pass = 0; pass < passes; ++pass) {
              const int64_t sourceOffset = (pass == 0 ? rank : 1 - rank) * stageChunk;
              const int64_t limit = scatter ? end : std::min(end, std::max<int64_t>(0, count - sourceOffset));
              for (int64_t step = 0; step < steps; ++step) {
                const int64_t valid = std::max<int64_t>(0, std::min(elements, limit - offset - step * elements));
                const auto& frame = frames[pass * steps + step];
                fixture::require(frame.bytes.size() == size_t(capacity), "Ring posted SGE length changed");
                fixture::zeroTail(frame, valid * sizeof(float));
              }
            }
          }
        }
      }
    }
  }
}
