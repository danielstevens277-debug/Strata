// include/strata/core/exchange_storage.hpp, host-only: the residency views the exchange rotation swaps.
//
// The case that matters is the chunked complement.  Its chunks are cut at expert boundaries, so a chunk's base is not a
// multiple of the blob size and an expert's bytes cannot be named by a slot index - the geometry that used to be
// rejected (and with the rotation then off, every complement large enough to need chunks, 28-34 GiB on a 16 GiB card,
// kept the copy path).  Each expert now carries its own host/device view, and a commit moves that view wholesale.
#include "strata/core/exchange_storage.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {
using strata::core::detail::ExchangeStorage;

int failures = 0;
void check(bool ok, const char* what) {
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", what); ++failures; }
}

// 4 resident experts in two chunks, plus expert 4 absent; one exchange slot.
// Chunk 0 holds experts 0-1, chunk 1 holds experts 2-3; chunk 1's base is deliberately not blob-aligned.
void chunked_complement() {
    constexpr size_t kBlob = 256;
    std::vector<uint8_t> chunk0(2 * kBlob), chunk1(2 * kBlob), exchange(1 * kBlob);
    uint8_t* other = reinterpret_cast<uint8_t*>(0x1000);   // device aliases: any distinct addresses will do
    const std::vector<uint64_t> offsets{0, kBlob, 0, kBlob, ~uint64_t{0}};
    const std::vector<const uint8_t*> host{chunk0.data(), chunk0.data() + kBlob,
                                           chunk1.data(), chunk1.data() + kBlob, nullptr};
    const std::vector<const uint8_t*> device{other, other + kBlob, other + 3 * kBlob, other + 4 * kBlob, nullptr};

    ExchangeStorage storage;
    std::string error;
    const bool init = storage.initialize(offsets, host, device, exchange.data(), other + 256 * 1024, 1, kBlob, error);
    check(init, error.empty() ? "chunked initialize" : error.c_str());
    if (!init) return;

    check(storage.active(), "active after initialize");
    for (size_t i = 0; i < 4; ++i) {
        check(storage.resident(i).host == host[i], "resident host view is the expert's own address");
        check(storage.resident(i).device == device[i], "resident device view is the expert's own alias");
    }
    check(storage.resident(4).host == nullptr, "an absent expert has no view");
    check(storage.spare(0).host == exchange.data(), "the spare is the exchange buffer");

    // Expert 1 leaves for the exchange buffer, expert 4 takes expert 1's chunk-relative address as the spare.
    check(storage.commit(1, 4, 0, exchange.data(), kBlob), "commit swaps ownership");
    check(storage.resident(4).host == exchange.data(), "the incoming expert reads the exchange buffer");
    check(storage.resident(4).device == other + 256 * 1024, "and its device alias");
    check(storage.resident(1).host == nullptr, "the evicted expert has no view");
    check(storage.spare(0).host == host[1], "the spare is the evicted expert's chunk address, not a slot stride");
    check(storage.exchanges() == 1 && storage.avoided_bytes() == kBlob, "the counters");

    // A second commit reuses that spare, which is how a chunk keeps rotating.
    check(storage.commit(2, 1, 0, host[1], kBlob), "second commit");
    check(storage.resident(1).host == host[1], "expert 1 is back at its own chunk address");
    check(storage.spare(0).host == host[2], "and the spare followed expert 2 out");

    // Expert 2 is the one absent now (it left on the second commit), so it is the legal destination; a resident one is not.
    check(storage.resident(2).host == nullptr, "expert 2 is absent after its own commit out");
    check(!storage.commit(1, 3, 0, host[2], kBlob), "a resident destination is refused");
    check(!storage.commit(0, 2, 0, exchange.data(), kBlob), "a wrong staged buffer is refused");
    check(!storage.commit(0, 2, 1, exchange.data(), kBlob), "a spare that does not exist is refused");
}

// The uniform arena the rotation was written for: every slot at a blob multiple of one base.
void single_arena() {
    constexpr size_t kBlob = 128;
    std::vector<uint8_t> arena(3 * kBlob), exchange(2 * kBlob);
    const std::vector<uint64_t> offsets{0, kBlob, ~uint64_t{0}, 2 * kBlob};
    std::vector<const uint8_t*> host, device;
    for (uint64_t at : offsets) {
        host.push_back(at == ~uint64_t{0} ? nullptr : arena.data() + at);
        device.push_back(at == ~uint64_t{0} ? nullptr : arena.data() + at);
    }
    ExchangeStorage storage;
    std::string error;
    const bool init = storage.initialize(offsets, host, device, exchange.data(), exchange.data(), 2, kBlob, error);
    check(init, error.empty() ? "uniform initialize" : error.c_str());
    if (!init) return;
    check(storage.commit(0, 2, 1, exchange.data() + kBlob, kBlob), "uniform commit");
    check(storage.resident(2).host == exchange.data() + kBlob, "uniform incoming view");
    check(storage.spare(1).host == arena.data(), "uniform spare is the arena's first slot");
}

// Geometry the rotation must keep refusing: an expert without a device address.
void malformed() {
    constexpr size_t kBlob = 64;
    std::vector<uint8_t> arena(2 * kBlob), exchange(kBlob);
    const std::vector<uint64_t> offsets{0, ~uint64_t{0}};
    const std::vector<const uint8_t*> host{arena.data(), nullptr};
    const std::vector<const uint8_t*> no_device{arena.data(), nullptr};
    std::vector<const uint8_t*> partial{arena.data(), nullptr};
    ExchangeStorage storage;
    std::string error;
    check(!storage.initialize(offsets, host, no_device, exchange.data(), nullptr, 1, kBlob, error),
          "no device alias for the exchange buffer is refused");
    error.clear();
    const std::vector<const uint8_t*> device_missing{nullptr, nullptr};
    check(!storage.initialize(offsets, host, device_missing, exchange.data(), exchange.data(), 1, kBlob, error),
          "a resident expert without a device address is refused");
    error.clear();
    const std::vector<const uint8_t*> short_device{arena.data()};
    check(!storage.initialize(offsets, host, short_device, exchange.data(), exchange.data(), 1, kBlob, error),
          "a view table that does not cover every expert is refused");
    check(!storage.active(), "a refused initialize leaves the storage inactive");
}
}  // namespace

int main() {
    chunked_complement();
    single_arena();
    malformed();
    if (failures != 0) { std::fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    std::printf("exchange_storage_test: PASS\n");
    return 0;
}
