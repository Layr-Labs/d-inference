// Deterministic unsigned-integer workload. The exact same binary runs on the
// host and guest; a matching checksum is required before comparing timings.
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

struct worker { uint64_t iterations, value; };

static void *compute(void *argument) {
    struct worker *worker = argument;
    uint64_t value = worker->value;
    for (uint64_t i = 0; i < worker->iterations; ++i) {
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        value *= UINT64_C(2685821657736338717);
    }
    worker->value = value;
    return NULL;
}

static uint64_t parse(const char *text, uint64_t maximum) {
    if (!text[0]) return 0;
    for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return 0;
    char *end;
    errno = 0;
    uint64_t value = strtoull(text, &end, 10);
    return errno || *end || value > maximum ? 0 : value;
}

static double seconds(struct timespec time) {
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    uint64_t count = argc == 3 ? parse(argv[1], 32) : 0;
    uint64_t iterations = argc == 3 ? parse(argv[2], UINT64_C(2000000000)) : 0;
    if (!count || !iterations) {
        fprintf(stderr, "usage: cpu WORKERS(1..32) ITERATIONS(1..2000000000)\n");
        return 64;
    }
    struct worker workers[32];
    pthread_t threads[32];
    struct timespec begin, end;
    if (clock_gettime(CLOCK_MONOTONIC, &begin)) return 70;
    for (uint64_t i = 0; i < count; ++i) {
        workers[i] = (struct worker){iterations, UINT64_C(0x9e3779b97f4a7c15) ^ (i + 1)};
        if (pthread_create(&threads[i], NULL, compute, &workers[i])) {
            for (uint64_t j = 0; j < i; ++j) pthread_join(threads[j], NULL);
            return 71;
        }
    }
    uint64_t checksum = 0;
    for (uint64_t i = 0; i < count; ++i) {
        if (pthread_join(threads[i], NULL)) return 71;
        checksum ^= workers[i].value;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &end)) return 70;
    printf("{\"schema_version\":1,\"workload\":\"integer_recurrence_v1\","
           "\"workers\":%" PRIu64 ",\"iterations\":%" PRIu64 ","
           "\"checksum\":\"%016" PRIx64 "\",\"elapsed_seconds\":%.9f}\n",
           count, iterations, checksum, seconds(end) - seconds(begin));
    return 0;
}
