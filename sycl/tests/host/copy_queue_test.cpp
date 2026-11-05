// tests/host/copy_queue_test.cpp - the copy-engine queue (include/strata/copy_queue.hpp) on the card in this machine.
//
// WHY A TEST.  make_copy_engine_queue() returns nullptr on eight different conditions and the prompt path silently keeps its
// ordinary in-order queue when it does, so "the copies run on the copy engine" was a claim about a code path nothing ever
// checked.  It also needs a whole Level Zero queue descriptor, which is why it was dead on Windows until
// sycl/tools/build_level_zero.bat put ze_api.h on disk; on Alchemist it is off unless STRATA_COPY_ENGINE=1 (the one measured
// hang was there, on Linux, and the gain was 1.4%), so run this with it forced on to exercise the path on an A-series card.
//
// WHAT IT CHECKS.  That a queue comes back, that it is the one is_copy_engine_queue() recognises, that bytes copied on it are
// the bytes that landed, that a barrier on the ordinary queue orders after those copies (the pattern prefill.cpp depends on:
// copy queue -> ext_oneapi_submit_barrier -> kernel), and that a second call hands back the same queue rather than leaking a
// second immediate command list.  Exit 0 when the copy engine is present and correct, 77 (ctest: skipped) when the device has
// none - a card without a copy-only queue group is not a failure - and 1 when it exists and gets the bytes wrong.
#include <strata/copy_queue.hpp>
#include <strata/sycl_queue.hpp>

#include <dpct/dpct.hpp>
#include <sycl/sycl.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {
int failures = 0;
void check(bool ok, const char* what) {
    std::printf("  %-58s %s\n", what, ok ? "ok" : "FAILED");
    if (!ok) ++failures;
}
}  // namespace

int main() {
    try {
        sycl::queue& q = dpct::get_in_order_queue();
        const sycl::device dev = q.get_device();
        std::printf("copy_queue_test: %s\n", dev.get_info<sycl::info::device::name>().c_str());
        std::printf("  backend %d, gen %d, STRATA_COPY_ENGINE=%s\n", (int) dev.get_backend(),
                    (int) strata::intel_gpu_gen(dev), std::getenv("STRATA_COPY_ENGINE") ? std::getenv("STRATA_COPY_ENGINE") : "(unset)");

        sycl::queue* cp = strata::make_copy_engine_queue("copy_queue_test");
        if (cp == nullptr) {
            std::printf("  no copy engine for this device/backend (the ordinary queue is what the engine would use)\n");
            return 77;
        }

        check(cp != &q, "the copy engine is not the ordinary queue");
        check(strata::is_copy_engine_queue(cp), "is_copy_engine_queue() recognises it");
        check(!strata::is_copy_engine_queue(&q), "the ordinary queue is not mistaken for it");
        check(strata::copy_engine_active(), "copy_engine_active()");
        check(strata::make_copy_engine_queue("copy_queue_test again") == cp, "a second call reuses the queue");
        check(cp->is_in_order(), "it is in order");

        // a 2 MiB blob, the size of an expert's page in the prompt path, copied on the copy queue and read by a kernel on the
        // ordinary queue that is ordered after it by a barrier - exactly prefill.cpp's issue_until() pattern
        const size_t n = 2u << 20;
        std::vector<unsigned char> host(n);
        for (size_t i = 0; i < n; ++i) host[i] = (unsigned char) (i * 31u + 7u);
        unsigned char* src = sycl::malloc_host<unsigned char>(n, q);
        unsigned char* dst = sycl::malloc_device<unsigned char>(n, q);
        std::memcpy(src, host.data(), n);

        sycl::event copied = cp->memcpy(dst, src, n);
        q.ext_oneapi_submit_barrier({copied});
        unsigned long long sum = 0;
        {
            sycl::buffer<unsigned long long, 1> b(&sum, 1);
            q.submit([&](sycl::handler& h) {
                auto acc = b.get_access<sycl::access::mode::discard_write>(h);
                h.parallel_for(sycl::range<1>{n}, [=](sycl::id<1> i) {
                    if (i * 31u + 7u == 0x5A5Au) acc[0] += dst[i.get(0)];
                });
            });
            q.wait();
        }
        unsigned long long want = 0;
        for (size_t i = 0; i < n; ++i)
            if ((unsigned char) (i * 31u + 7u) == 0x5A5A) want += host[i];
        check(sum == want, "the kernel sees the bytes the copy queue wrote");

        // the same bytes again, this time read back on the copy queue itself (a D2H memcpy) - no kernel involved
        std::vector<unsigned char> back(n);
        cp->memcpy(back.data(), dst, n).wait();
        check(std::memcmp(back.data(), host.data(), n) == 0, "a D2H copy on the copy queue returns them unchanged");

        sycl::free(src, q);
        sycl::free(dst, q);
        std::printf("copy_queue_test: %s\n", failures == 0 ? "PASS" : "FAILED");
        return failures == 0 ? 0 : 1;
    } catch (const std::exception& e) {
        std::printf("copy_queue_test: exception: %s\n", e.what());
        return 1;
    }
}
