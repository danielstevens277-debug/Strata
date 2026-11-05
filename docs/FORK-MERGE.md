# Merge record: the Strata-32GB fork's expert-file tier

The fork `Strata-32GB` and this tree share `src/core/expert_source.*`.  The fork's later changes to the file tier
were merged here, in the native tree and in `sycl/` alike; this note says what came over, what did not, and how
to turn each piece on.

## Merged

| Feature | Where | Env | Default |
|---|---|---|---|
| Overlapped read landing in the stage buffer itself (no scratch copy) | `claim_stage`, `read_direct` | `STRATA_DIRECT_IN_PLACE` | on (Windows, unbuffered `experts.bin` only) |
| Two drives for one `experts.bin`, each read split between them | `open_direct`, `read_direct` | `STRATA_EXPERTS_MIRROR`, `STRATA_EXPERTS_MIRROR_SHARE` | off |
| Reader threads kept between layers instead of started per batch | `KeptReaders`, `fill_many` | `STRATA_COLD_KEPT_READERS`, `STRATA_COLD_READER_CPU`, `STRATA_COLD_READER_CPUS` | off |

`read_direct` takes a batch of `Fill`s where `dst` is the *blob* (the buffer plus its sector remainder) and
`in_place` says whether the drive may write the blob's sectors straight in.  The stage buffer is then 4 KiB
aligned with two spare sectors, `stage_skip_` holds the remainder and `stage_in_place_` the flag; `stage_ptr(v)`
is what hands the blob to a caller, `stage_buf_[v].get()` is only the allocation.

Because a request can now land in the caller's buffer instead of the thread's scratch, a request is a `Req`
(one range the caller asked for) plus one or more `Io`s (what each drive is actually asked for).  A mirrored
request is two `Io`s writing into the two halves of the same range, and their completion counts add up to the
request's.  An in-place request has no scratch offset and is never merged into a neighbour, since merging would
write past it.

One allocator note: an aligned allocation that fails falls back to a pageable buffer, and the buffer must then
record `aligned = false`, or the free would call `_aligned_free` on a `new[]` pointer.

## Not merged (deliberate)

* **Read-through RAM tier** (`STRATA_RAM_THROUGH`, `STRATA_RAM_ADAPT_PAR`).  It needs the RAM places padded to
  4 KiB and retargeted per layer, which the SYCL port's chunked USM complement does not do yet, so the SYCL
  file tier prints a note rather than silently running the old path.  Port order: pad and retarget the places,
  then the landing write, then the adaptive swaps.
* **The `nv_defaults` SM89 entry and the `--fast-setup` tooling.**  NVIDIA-only; the SYCL backend never reads
  them.

## Verifying

Every switch is A/B-able on one pack: run the same prompt with the env unset and set, and compare the
`FileExpertSource` counters in the log (`io_pf_*`, `file_us_`, `file_blob_bytes_`).  `STRATA_DIRECT_IN_PLACE=0`
must reproduce the previous scratch-copy path byte for byte; that is the arm to fall back to if a drive or a
filter driver refuses sector-aligned overlapped reads.
