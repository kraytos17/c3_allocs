# c3_allocs

`c3_allocs` is a C3 project for experimenting with memory allocators that
implement the standard library's `std::core::mem::alloc::Allocator` interface.

## Current status

The repository currently contains ten allocators and one debug wrapper:

- **`ArenaAllocator`** — a fixed-capacity arena backed by a caller-provided
  byte slice. It supports alignment, zero-initialized allocation, resize,
  last-allocation release, and mark/reset bulk reclamation.
- **`PoolAllocator`** — a fixed-capacity pool that divides caller-provided
  storage into equal-sized slots and reuses individual slots after release.
- **`PoolChainAllocator`** — a chain of fixed-size pools over up to
  `POOL_CHAIN_MAX` caller-provided buffers. Each request is served from
  the first link with a free slot, so capacity grows by attaching more
  buffers instead of failing.
- **`BackedArenaAllocator`** — an arena that starts in a caller-provided buffer
  and obtains individual overflow blocks from a backing allocator. It supports
  marks and frees overflow blocks when resetting to an earlier mark.
- **`FreeListAllocator`** — a variable-size allocator over caller-provided
  storage. It uses first-fit selection, splits on allocate, and coalesces
  neighbours on release. It supports in-place shrink and growth into an
  adjacent free range, otherwise it moves on resize.
- **`SizeClassAllocator`** — a dispatcher that routes requests to the
  smallest fitting fixed-size pool. It bounds waste for mixed sizes while
  keeping pool O(1) release and stable pointers.
- **`TypedPool{Type}`** — a generic wrapper that derives slot size and
  alignment from a type, returning typed pointers from `acquire`.
- **`ScratchAllocator`** — a single-frame allocator wrapping an arena with
  a high-water mark for tuning frame buffer sizes.
- **`BuddyAllocator`** — a binary buddy allocator over caller-owned memory.
  It carves the largest aligned power-of-two region from the buffer, splits
  blocks on demand, and merges a freed block with its free buddy (found by
  address XOR), so full release restores one contiguous block.
- **`BitmapBuddyAllocator`** — a headerless binary buddy allocator. Per-order
  `alloc`/`split` bitmaps carved from the region front replace per-block
  headers, so a 16-byte request consumes exactly 16 bytes. The block order
  is recovered from the split bits on release. It trades the per-request
  trailing canary for that header saving.
- **`TrackingAllocator`** — a debug wrapper that records every acquire,
  resize, and release through it. The `trk_malloc`/`trk_calloc`/
  `trk_realloc`/`trk_free` macros capture the call site via the `$$FILE` /
  `$$FUNC` / `$$LINE` builtins, leaks are reported with those sites, and
  double releases are detected without reaching the wrapped allocator.

## Requirements

- The C3 compiler, `c3c`, with support for language revision 0.8.6 and above.
- GNU Make for the convenience targets below.
- `c3fmt` is optional; it is used by the formatting targets.

The Makefile uses `c3c` and `c3fmt` from `PATH` by default. Override either
command when needed, for example:

```sh
make C3C=/path/to/c3c build
make C3FMT=/path/to/c3fmt fmt-check
```

## Build, run, test, and format

Run these commands from the repository root:

```sh
make             # Show available targets (the default)
make build       # Compile the executable
make run         # Build and run the executable
make test        # Run the C3 test suite
make bench       # Run the allocator benchmarks
make fmt-check   # Check C3 formatting without changing files
make fmt         # Format C3 files in place
make check       # Run fmt-check, test, and build in sequence
make fuzz        # Run fuzzer smoke: fixed seeds across all allocators
make fuzz-long   # Deep fuzz run (SEED, ITERATIONS, MAXLIVE overrides)
make fuzz-hf     # Bounded honggfuzz session (HF_N, HF_TIMEOUT, HF_THREADS)
make fuzz-hf-cov # Same, with clang coverage feedback (guided)
make clean       # Remove C3 build artifacts
```

`make all` is an alias for `make build`. Build outputs are written under
`build/`. The `make fmt` target edits files in `src/` and `test/`; review its
changes before committing them. Formatting rules are in the root `.c3fmt` file.

Pushes and pull requests also run `.github/workflows/ci.yml`, which
installs `c3c` v0.8.6 from the official release assets and then runs
`make check` (format check, full test suite, build), `make bench`,
and `make fuzz` (fuzzer smoke across fixed seeds).

### Fuzzing

`fuzz/fuzz.c3` is a seeded differential-stress harness covering all
allocators, separate from the unit tests so long runs do not slow the
fast suite. Each scenario runs tens of thousands of mixed
acquire/release/resize operations with edge-case sizes (0, boundaries
around 8/16/32/64, uniform 1–256), alignments (0, 8–64, plus invalid 3),
hostile releases (duplicates, interior and foreign pointers, null),
and deliberate canary corruption that must trigger the `-O2` guards
(failed resize, ignored release). Oracles include the free-list
`debug_verify()`, canary sampling over all live blocks, slot/byte
accounting on every operation, and full state restore at the end. Any
failure prints the seed, the failing operation, and a 64-operation ring
log, so `make fuzz-long SEED=<n>` reproduces it exactly:

```sh
make fuzz                                  # Smoke: seeds 1-3, ~1s total
make fuzz-long SEED=5 ITERATIONS=50000 MAXLIVE=128
```

The same scenarios also run under honggfuzz (`docs/fuzz-honggfuzz.md`):
`fuzz/fuzz_hf.c3` exposes them through a libhfuzz persistent entry
point (the same binary still takes a file path for corpus validation
and triage) and builds with `--sanitize=address`, so memory errors
become honggfuzz-recorded crashes while oracle violations abort.
`make fuzz-hf` runs a bounded persistent session (~5000 execs/s here);
`make fuzz-hf-cov` rebuilds through LLVM IR with clang coverage
instrumentation for guided fuzzing;
a weekly CI job runs the long session and uploads new coverage.

## Benchmarks

`make bench` runs `bench/allocators_bench.c3` through `c3c compile-benchmark`.
Each benchmark performs a fixed batch of operations per iteration, so the
reported average is per batch, not per allocation:

- `bench_freelist_*_acquire_release` — hot-path acquire/release pairs for
  the arena, backed arena, free-list, buddy, bitmap buddy, pool, pool
  chain, and size-class dispatch. The free-list pair covers both policies:
  `FIRST_FIT` (default) and `BEST_FIT`, which scans every range before
  choosing. The bitmap buddy pair contrasts 64-byte and 16-byte requests,
  and the tracking bench shows the debug wrapper's overhead over the plain
  free-list path. The pool chain bench stays on the first link, so it
  measures the routing overhead over a plain pool.
- `bench_*_clear_cycle` — fill then bulk reset for arena, buddy, free-list,
  and scratch, measuring the O(1) bulk-reclaim cost.
- `bench_freelist_fragmented_release` — release alternating blocks to
  exercise split/merge churn on the free list.

Numbers vary by machine; compare within one run rather than across runs.
Per-allocation overhead is observable through the byte stats instead
(`bytes_reserved` vs payload, `bytes_used` vs `bytes_free`).

One reference run on my machine (64-byte requests unless noted, batches of
64 operations, 65536-byte buffers; averages, lower is better):

| Benchmark                            | Avg per batch |
| ------------------------------------ | ------------- |
| arena acquire/release                | 0.36 us       |
| backed arena acquire/release         | 0.52 us       |
| pool acquire/release                 | 1.55 us       |
| pool chain acquire/release           | 1.60 us       |
| free-list first-fit acquire/release  | 1.09 us       |
| free-list best-fit acquire/release   | 0.93 us       |
| tracking over free-list acquire/release | 2.56 us    |
| size-class acquire/release           | 2.11 us       |
| buddy acquire/release                | 1.74 us       |
| bitmap buddy acquire/release         | 4.00 us       |
| bitmap buddy 16-byte acquire/release | 5.49 us       |
| arena clear cycle                    | 0.27 us       |
| scratch clear cycle                  | 0.33 us       |
| free-list clear cycle                | 0.58 us       |
| buddy clear cycle                    | 0.72 us       |
| free-list fragmented release         | 1.05 us       |

The numbers are from an `-O2` build (`make bench` now passes `-O2` to the
compiler); auto-vectorization pays off across the board. The bitmap buddy
stays slower per operation than the headered one because release walks
the split bits to recover the order; its win is zero per-allocation
metadata for tiny requests. Tracking overhead is about 3.4x here:
the wrapped path got five times faster while the map-based bookkeeping
stays constant, which is expected for a debug wrapper.

One `-O2` caveat: `assert` and doc-comment `@require` contracts are
optimization assumptions, not just stripped checks — the compiler may
use them to delete code on the "impossible" path or miscompile a
violation outright (observed: wrong results, `SIGSEGV`, `SIGILL`).
Corruption and validation checks that must survive optimization are
therefore plain runtime guards with no `assert`/`@require` on the
same condition: a corrupted trailing canary fails `resize` with
`INVALID_ALLOC_SIZE` and makes `release` ignore the block; an invalid
`init` leaves the allocator empty; an out-of-range arena `reset` is
ignored. All hold at every optimization level.

## Choosing an allocator

| Need                                              | Use                   |
| ------------------------------------------------- | --------------------- |
| Per-frame or scoped transient data                | `ScratchAllocator`    |
| Grouped lifetimes with nested rewind              | `ArenaAllocator`      |
| Mostly-fits buffer with occasional overflow       | `BackedArenaAllocator`|
| One fixed size, O(1) release, stable pointers     | `PoolAllocator`       |
| One fixed size, but capacity must grow at runtime | `PoolChainAllocator`  |
| Typed slots derived from a struct                 | `TypedPool{Type}`     |
| Mixed small sizes with bounded waste              | `SizeClassAllocator`  |
| General variable sizes inside one buffer          | `FreeListAllocator`   |
| Variable sizes with minimal external fragmentation| `BuddyAllocator`      |
| Tiny allocations where headers cost too much      | `BitmapBuddyAllocator`|

Rules of thumb: prefer the simplest allocator that covers the lifetime
pattern; arenas and scratch beat everything on speed but cannot free
individually in the middle; pools beat free lists when sizes are uniform;
buddy is the safest default for unpredictable mixed sizes, at the cost of
power-of-two rounding.

## Using `ArenaAllocator`

The arena borrows its backing buffer. That buffer must remain alive for as long
as the arena and any pointers allocated from it are used.

```c3
import std::core::mem::alloc;
import c3_allocs::allocators;

char[4096] storage;
allocators::ArenaAllocator arena;
arena.init(storage[..]);

char* bytes = alloc::malloc(&arena, 128);
// Use bytes while storage and arena remain alive.
alloc::free(&arena, bytes);

arena.clear(); // Invalidates all allocations made from the arena.
```

### Allocation behavior

- The arena has fixed capacity and does not request more backing memory. An
  allocation that does not fit returns an allocation error.
- Alignment `0` requests the default C3 memory alignment. Non-zero alignments
  must be valid C3 alignments; invalid values are rejected.
- `AllocInitType.ZERO` clears the requested allocation. `NO_ZERO` leaves it
  uninitialized.
- Direct calls to `acquire` reject zero or negative sizes. The standard `alloc`
  helper layer has its own zero-size behavior.
- A failed allocation does not advance the arena's used position.

### Release and bulk reclamation

`release` can reclaim space only when given the most recently allocated block.
Releasing an earlier block has no effect, and freeing it does not make its
space reusable while later allocations remain. When releasing blocks in
last-in-first-out order, each release can reclaim the latest block.

Use `mark` and `reset` to reclaim allocations made after a saved position, or
`clear` to discard all arena allocations:

```c3
sz mark = arena.mark();
char* temporary = alloc::malloc(&arena, 256);
// Use temporary before resetting.
arena.reset(mark); // Invalidates allocations made after mark.
```

After `reset` or `clear`, do not use pointers to allocations that were
invalidated. These operations do not zero the backing buffer or run destructors
for values stored in it.

### Resize behavior

`resize` preserves the byte prefix up to the smaller of the old and new sizes.
It resizes the most recent block in place when the pointer meets the requested
alignment and the new size fits. Otherwise, it tries to allocate a replacement
block and copy the old contents. This can move a non-last block, but the old
block remains reserved because it is no longer the latest allocation.

If replacement allocation fails, resize returns an error and preserves the old
block and arena state. When the newest block already meets the requested
alignment but cannot extend in place, resize fails rather than moving it. If the
requested alignment requires a different address, the arena may instead
allocate a replacement and copy the contents, provided enough unused capacity
remains.

Group allocations by alignment to cut padding waste: allocate all
high-alignment objects first, then the low-alignment ones. Interleaving
alignments forces padding before almost every block, while grouped order
pays it once per alignment level.

### Limitations

- The arena is not thread-safe; synchronize access externally if sharing it.
- Resetting or clearing invalidates pointers into reclaimed storage.
- Values that require cleanup are not automatically destroyed when storage is
  released or reset. Arrange any required cleanup before invalidating their
  storage.

## Using `PoolAllocator`

`PoolAllocator` is intended for workloads with many allocations that fit a
common maximum size. Initialization sets the maximum payload size and supported
alignment; the pool calculates how many slots fit in the supplied buffer.

```c3
import std::core::mem::alloc;
import c3_allocs::allocators;

char[4096] storage;
allocators::PoolAllocator pool;
pool.init(storage[..], 64, 16); // 64-byte payloads, up to 16-byte alignment.

void* item = alloc::malloc(&pool, 48);
// Use item while storage and pool remain alive.
alloc::free(&pool, item); // The released slot can be reused.
```

### Pool behavior and constraints

- The pool borrows its buffer; the buffer must outlive the pool and its
  allocations.
- The pool has a fixed number of equal-sized slots. `capacity()` reports the
  slot count, `available()` the free slots, and `payload_size()` the maximum
  payload per slot. `owns()` tests whether a pointer is a slot payload.
- Use `pool_init_for{Type}(&pool, storage[..])` to size slots from a type
  instead of passing raw sizes.
- Requests larger than the configured payload size, with unsupported
  alignment, or after all slots are in use fail without consuming a slot.
- `release` makes a valid slot available for reuse. Null, foreign,
  interior, duplicate-release, and canary-corrupted pointers are
  ignored.
- `resize` stays in the same slot and can only change the requested size up to
  the configured payload size. It never moves or grows the slot. A
  corrupted canary fails the resize with `INVALID_ALLOC_SIZE`.
- The pool is not thread-safe and does not run destructors for values stored
  in its memory.

## Using `PoolChainAllocator`

`PoolChainAllocator` extends the pool with spillover: it manages up to
`POOL_CHAIN_MAX` fixed-size links and serves each request from the first
link with a free slot. When every link is full, attach another buffer
with `attach` instead of failing.

```c3
import std::core::mem::alloc;
import c3_allocs::allocators;

char[4096] first_storage;
char[4096] spare_storage;
char[][1] bufs = { first_storage[..] };
allocators::PoolChainAllocator chain;
chain.init(bufs[..], 64, 16); // 64-byte payloads, up to 16-byte alignment.

void* item = alloc::malloc(&chain, 48);
// Use item while the buffers and chain remain alive.
alloc::free(&chain, item); // The slot returns to whichever link owns it.
chain.attach(spare_storage[..]); // Adds a second link when needed.
```

### Pool chain behavior and constraints

- The chain borrows one buffer per link; every buffer must outlive the
  chain and its allocations. `attach` borrows the same way.
- All links share the block size and alignment, so any slot serves any
  request and blocks never move between links. `payload_size()` reports
  the shared size; `capacity()` and `available()` sum across links.
- `link_count()` reports the configured links, `link_capacity(i)` and
  `link_available(i)` inspect one link (zero for a bad index).
- `acquire` scans links in order and uses the first free slot. Requests
  larger than the block size report `INVALID_ALLOC_SIZE`; a full chain
  reports `OUT_OF_MEMORY`. `init` with no usable buffers, and `attach`
  past the link limit, leave the chain (or fail) without changing state.
- `release` routes to the owning link; null, foreign, interior, and
  duplicate releases are ignored. `owns()` and `canary_intact()` route
  the same way; `debug_verify()` checks every link.
- `resize` stays in the owning link's slot, exactly like a pool resize.
- The chain is not thread-safe and does not run destructors.

## Using `BackedArenaAllocator`

`BackedArenaAllocator` is for workloads that mostly fit in a fast initial buffer
but occasionally need more memory. The initial buffer is borrowed. Overflow
allocations are acquired from the supplied backing allocator and are owned by
the backed arena until individually released or invalidated by reset/clear.

```c3
import std::core::mem::alloc;
import c3_allocs::allocators;

char[1024] initial_storage;
allocators::ArenaAllocator backing;
char[8192] backing_storage;
backing.init(backing_storage[..]);

allocators::BackedArenaAllocator arena;
arena.init(initial_storage[..], &backing);

sz mark = arena.mark();
char* data = alloc::malloc(&arena, 2048); // Uses backing storage if needed.
// Use data before resetting to mark.
arena.reset(mark); // Frees overflow allocations made after the mark.
arena.free(); // Frees remaining overflow blocks; initial_storage is borrowed.
```

### Backed arena behavior and constraints

- The initial buffer and the backing allocator must both outlive the arena and
  any allocations that remain in use.
- Each overflow request is a separate backing allocation; this allocator does
  not grow and subdivide overflow chunks. The backing allocator must be able to
  allocate the page metadata plus payload as one block.
- `mark` returns a position in this arena's history and `reset` invalidates
  later allocations. Reset releases overflow blocks created after the mark and
  rewinds initial-buffer allocations after it. Reusing a mark after resetting
  to it is allowed. Marks are positional, not identities: after a rewind,
  an older mark at the same position refers to the new history. A mark
  ahead of the current position, or from another arena, must not be used.
  `clear` resets to the beginning; `free` also detaches the arena from its
  borrowed initial buffer and backing allocator, so it must be
  reinitialized before further use.
- `release` frees overflow blocks immediately, unless the block's canary
  is corrupted (then the block is ignored). For allocations inside the
  initial buffer, only a last-in-first-out release sequence reclaims
  space.
- `initial_served()` and `overflow_served()` count lifetime allocations per
  path. A high overflow share means the initial buffer is undersized for
  the workload.
- `reset_retaining(mark)` parks overflow pages in an internal pool instead
  of freeing them, so steady-state frame loops stop calling the backing
  allocator. `page_pool_count()` reports parked pages and `prune_pool()`
  returns them to the backing allocator. `reset` and `clear` always free;
  `free` also drains the pool. When a pooled page is too small for a
  request, its backing block is grown through the backing allocator first;
  because a pooled page holds no live data, this is safe even when the
  backing allocator moves the block. Live pages are never grown, since
  that would relocate their payloads.
- `resize` preserves the common prefix. It may resize the newest initial-buffer
  allocation in place; otherwise it acquires a replacement before releasing
  the old allocation. On failure, it leaves the original allocation valid.
  A corrupted overflow canary fails with `INVALID_ALLOC_SIZE`.
- The arena is not thread-safe. Reset/free do not run destructors.

## Using `FreeListAllocator`

`FreeListAllocator` manages variable-size blocks inside a borrowed buffer.
First-fit selection splits a free range on allocate, and release merges
adjacent free neighbours, so freeing everything restores one contiguous
range (minus any initial alignment offset).

```c3
import std::core::mem::alloc;
import c3_allocs::allocators;

char[4096] storage;
allocators::FreeListAllocator list;
list.init(storage[..]);

void* item = alloc::malloc(&list, 48);
alloc::free(&list, item); // The range is freed and coalesced.
list.clear(); // Discards all allocations at once.
```

### Free-list behavior and constraints

- The buffer is borrowed; it must outlive the allocator and its allocations.
- The free list is doubly linked in most-recently-freed order, and every
  free range carries a 16-byte boundary footer at its end, following the
  classic Knuth boundary-tag design. Release finds and merges free
  neighbours in constant time, so it stays fast no matter how fragmented
  the buffer is. A free range costs 48 bytes (node plus footer), and
  ranges smaller than that are consumed whole rather than split.
- `capacity()` reports the borrowed length, `bytes_free()` reports free
  ranges, and `bytes_used()` reports borrowed bytes not currently free.
  `largest_free()` reports the biggest contiguous range and
  `free_block_count()` reports how many ranges exist.
- `acquire` aligns payloads, supports `ZERO` init, and leaves state unchanged
  on failure. A range is split only when the remainder can hold a free node
  plus its footer.
- `release` ignores null, foreign, interior, duplicate, and
  canary-corrupted releases, then coalesces with adjacent free
  neighbours through the boundary tags. The
  footer is only trusted together with the node at the implied range
  start, so forged footers in user data do not corrupt the list.
- Selection is `FIRST_FIT` by default; `set_policy` switches to `BEST_FIT`,
  which scans all ranges and picks the smallest fitting one, breaking ties
  by lower address. `FIRST_FIT` is fastest; `BEST_FIT` leaves fewer small
  splinters when sizes vary widely.
- `resize` preserves the prefix. It shrinks in place, grows into an adjacent
  free range when possible (identified by the boundary node in constant
  time), otherwise moves. Failure preserves the original, including a
  corrupted-canary failure, which reports `INVALID_ALLOC_SIZE`.
- `largest_free()` reports the biggest contiguous range and
  `free_block_count()` how many ranges exist. Allocations larger than
  `largest_free` fail even when `bytes_free` is bigger.
- The allocator is not thread-safe and does not run destructors.

## Using `TrackingAllocator`

`TrackingAllocator` wraps any allocator (the wrapped allocator is stored as
an `Allocator` interface value) and records every acquire, resize, and
release. The `trk_*` macros capture the call site; direct interface calls
are tracked with an unknown site.

```c3
import std::core::mem::allocators;
import c3_allocs::allocators;

allocators::FreeListAllocator list;
list.init(storage[..]);

allocators::TrackingAllocator tracker;
tracker.init(&list);

void*? item_opt = allocators::trk_malloc(&tracker, 48);
if (catch item_opt) return;
allocators::trk_free(&tracker, item_opt);

if (!tracker.check_no_leaks()) tracker.report_leaks();
tracker.free();
```

### Tracking behavior and constraints

- `live_count()`, `live_bytes()`, and `total_count()` report running
  totals; `double_releases()` counts releases that did not match a live
  tracked pointer.
- Unmatched releases are not forwarded to the wrapped allocator, which
  keeps a double release from tripping the backing allocator's own
  detection.
- `report_leaks()` prints one line per live allocation with its recorded
  file, function, and line; `check_no_leaks()` is the boolean form.
- The record array is served by the wrapped allocator and grows by
  doubling; the pointer map uses the global allocator, so an exhausted
  backing never breaks bookkeeping. `free()` releases both; check for
  leaks first.
- The wrapper is not thread-safe.

## Using `SizeClassAllocator`

`SizeClassAllocator` routes mixed-size requests across fixed-size pools.
Each class is a `PoolAllocator` over its own borrowed buffer, so blocks
never move and release stays O(1). `acquire` picks the smallest class that
fits and has a free slot, bounding waste to the gap between classes.

```c3
char[512] small_buf;
char[512] large_buf;
char[][2] bufs = { small_buf[..], large_buf[..] };
sz[2] sizes = { 32, 256 };
allocators::SizeClassAllocator sc;
sc.init(bufs[..], sizes[..]);

void* item = alloc::malloc(&sc, 24); // Served by the 32-byte class.
alloc::free(&sc, item);
```

For the common case there is a preset constructor: give it one buffer and
a class count, and it splits the buffer evenly across a stepped table of
`24 << k` byte classes (24, 48, 96, 192, 384, ...):

```c3
char[5120] storage;
allocators::SizeClassAllocator sc;
sc.init_preset(storage[..], 5); // Classes 24, 48, 96, 192, 384.
```

### Size-class guidance

- Prefer stepped tables where most requests land, then factored growth:
  for example 24, 48, 96, 192, 384. Wide gaps waste memory on every
  allocation in the upper class.
- Classes you never use still reserve their whole buffer, so only configure
  sizes you actually allocate. Unused capacity shows up as a large
  `class_available()` on an idle class.
- `capacity()` and `available()` sum across classes; `class_block_size(i)`
  and `class_available(i)` inspect one class. Requests larger than every
  class report `INVALID_ALLOC_SIZE`; a full fitting class reports
  `OUT_OF_MEMORY`.
- `init_preset` divides one buffer evenly across classes. With a small
  count, later preset classes are absent, so requests larger than the
  biggest configured class fail.

## Using `ScratchAllocator`

`ScratchAllocator` is a single-frame allocator: a thin `ArenaAllocator`
wrapper with a high-water mark. Allocate freely during the frame, then
`clear()` once at the frame boundary.

```c3
allocators::ScratchAllocator scratch;
scratch.init(storage[..]);

void* tmp = alloc::malloc(&scratch, 64);
// ... frame work ...
scratch.clear(); // One O(1) bulk reset for the next frame.
```

- `peak()` reports the highest reserved bytes since init or `reset_peak`.
  Size the buffer from it: grow when `peak` nears `capacity`, shrink when
  it stays far below.
- `mark`/`reset`/`release`/`resize` match arena semantics; `clear()` keeps
  the peak so tuning survives across frames.

## Using `BuddyAllocator`

`BuddyAllocator` manages variable-size blocks with minimal external
fragmentation. Orders double from 64 bytes; each request rounds up to the
smallest order covering header, padding, and payload. Splits publish the
right-hand buddy and descend left; release merges upward while the XOR
buddy is free.

```c3
char[4096] storage;
allocators::BuddyAllocator buddy;
buddy.init(storage[..]);

void* item = alloc::malloc(&buddy, 48);
alloc::free(&buddy, item); // Merges with its free buddy when possible.
```

### Buddy behavior and constraints

- The buffer is borrowed. Only the carved power-of-two region is managed;
  leading and trailing bytes stay reserved but unused. `capacity()`
  reports the region size, not the buffer length.
- Requests larger than the region report `INVALID_ALLOC_SIZE`; exhaustion
  reports `OUT_OF_MEMORY`. Failure leaves state unchanged.
- `largest_free()` and `free_block_count()` mirror the free-list queries:
  a request larger than `largest_free` fails even when `bytes_free` is
  bigger. `clear()` restores one block.
- `resize` shrinks in place and otherwise moves with prefix preservation.
  A corrupted canary fails the resize with `INVALID_ALLOC_SIZE`.
- The allocator is not thread-safe and does not run destructors.

## Using `BitmapBuddyAllocator`

`BitmapBuddyAllocator` is the headerless variant of the buddy allocator.
Per-order `alloc` and `split` bitmaps are carved from the front of the
region; every block byte is payload, and the block order is recovered from
the split bits on release instead of a header.

```c3
char[4096] storage;
allocators::BitmapBuddyAllocator buddy;
buddy.init(storage[..]);

void* item = alloc::malloc(&buddy, 16); // Consumes exactly 16 bytes.
alloc::free(&buddy, item);
```

### Bitmap-buddy behavior and constraints

- Orders double from a 16-byte leaf. A request's cost is the covering
  block, with no header, so tiny allocations waste almost nothing.
- The managed base is aligned to the served block size so any valid
  alignment up to the top block works; carving bitmaps plus that alignment
  costs region capacity, which `capacity()` reports honestly.
- There is no per-request canary (there is no header to locate it). Test
  builds poison whole freed blocks; double releases are detected through
  the `alloc` bit and ignored.
- `largest_free()`, `free_block_count()`, `bytes_free()`/`bytes_used()`,
  `owns()`, and `clear()` mirror the headered buddy. `resize` shrinks in
  place, otherwise moves with prefix preservation.
- The allocator is not thread-safe and does not run destructors.

### Shared core and typed helpers

- `src/allocators/common.c3` holds the shared alignment, padding,
  effective-alignment, range, and split helpers used by all allocators.
  They are public so custom allocators can reuse them; file-local helpers
  stay `@local`.
- Use the standard `alloc::new` / `alloc::new_try` macros for typed
  allocation; they derive size and alignment from the type. For pools, use
  `pool_init_for{Type}(&pool, storage[..])` to size slots from a type, or
  `TypedPool{Type}` for a fully typed facade:

```c3
allocators::TypedPool{PoolTestPoint} pool;
pool.init(storage[..]);
PoolTestPoint*? point_opt = pool.acquire();
if (catch point_opt) return;
PoolTestPoint* point = point_opt;
pool.release(point);
```

## Ownership and LIFO queries

Every allocator exposes `owns(pointer)` to test whether a pointer belongs
to it. Semantics differ where the data structure dictates:

- `PoolAllocator`, `SizeClassAllocator`, `FreeListAllocator`,
  `BuddyAllocator`, and `BackedArenaAllocator` validate allocation
  metadata: only exact payload pointers report true; interior and foreign
  pointers report false.
- `ArenaAllocator` and `ScratchAllocator` do a range check like the
  standard library's fixed-buffer allocator: interior pointers count.
- `ArenaAllocator` and `ScratchAllocator` also expose `is_last(pointer)`
  for the newest-allocation check that governs their LIFO release
  behavior. The pointer must be a payload the allocator returned.

## Debug hardening

The header-carrying allocators protect payloads with a trailing canary,
similar to mimalloc's debug mode:

- On `acquire`, every byte between the requested payload end and the end
  of the block is filled with `0xC3`. When the block packs exactly, the
  canary region is empty and the check is trivially true.
- On the in-place paths of `resize`, the canary is verified; a mismatch
  fails the resize with `INVALID_ALLOC_SIZE` and preserves the block.
  On `release`, a mismatch ignores the block: leaking is safer than
  merging a possibly-overwritten range. These are runtime checks, so
  they hold at `-O2` where `assert` is compiled out. The canary is
  refilled after in-place shrinks and grows.
- `PoolAllocator`, `FreeListAllocator`, `BuddyAllocator`, and overflow
  pages of `BackedArenaAllocator` participate. Initial-buffer allocations
  of `BackedArenaAllocator` have no trailing slack and are not covered.
  Backed-arena overflow blocks round up to 16 bytes so a canary fits.
- `canary_intact(pointer)` is a public query on the covered allocators for
  checking a live payload at any time. The pointer must be a payload the
  allocator returned.
- `FreeListAllocator.debug_verify()` checks the free-list invariants
  (node magic and links, footers, buffer containment, non-overlap, and
  the `free_bytes` total). It runs automatically at the end of every
  mutating free-list operation in test builds, and is a public query
  for hand-rolled sequences in tests.
- On `release` under test builds (`env::TESTING`), the released payload
  region is poisoned with `0xAA`, matching the standard library's test
  fills, so use-after-release reads are visible. Release builds skip
  poisoning.

## Repository layout

- `src/allocators/common.c3` — shared alignment helpers.
- `src/allocators/arena.c3` — the arena implementation.
- `src/allocators/pool.c3` — the fixed-slot pool implementation.
- `src/allocators/poolchain.c3` — the chained pool implementation.
- `src/allocators/backed_arena.c3` — the arena with backing-allocator overflow.
- `src/allocators/freelist.c3` — the variable-size free-list implementation.
- `src/allocators/buddy.c3` — the binary buddy allocator.
- `src/allocators/bitmap_buddy.c3` — the headerless bitmap buddy allocator.
- `src/allocators/sizeclass.c3` — the size-class dispatcher over pools.
- `src/allocators/scratch.c3` — the single-frame scratch allocator.
- `src/allocators/typed.c3` — the generic typed pool facade.
- `src/allocators/tracking.c3` — the tracking debug wrapper and `trk_*`
  macros.
- `src/main.c3` — executable entry point.
- `bench/allocators_bench.c3` — allocator benchmarks run by `make bench`.
- `fuzz/fuzz.c3` — seeded stress harness run by `make fuzz`.
- `fuzz/fuzz_common.c3` — shared scenarios and oracles for both runners.
- `fuzz/fuzz_hf.c3` — honggfuzz entry point; input file drives the stream.
- `fuzz/make_corpus.py` — deterministic corpus generator (see below).
- `fuzz/corpus/` — honggfuzz seed inputs (git-ignored, regenerative).
- `docs/fuzz-honggfuzz.md` — honggfuzz setup, commands, and triage.
- `test/arena_test.c3`, `test/pool_test.c3`, `test/backed_arena_test.c3`,
  `test/freelist_test.c3`, `test/buddy_test.c3`,
  `test/bitmap_buddy_test.c3`, `test/sizeclass_test.c3`,
  `test/scratch_test.c3`, `test/debug_test.c3`, `test/tracking_test.c3`,
  `test/common_test.c3`, `test/stress_test.c3`,
  `test/poolchain_test.c3`, and
  `test/hardening_test.c3` — allocator behavior, failure-path, storm,
  alignment-torture, and canary-guard tests.
- `project.json` — C3 compiler project configuration.
- `Makefile` — build, test, formatting, and clean targets.
- `.github/workflows/ci.yml` — the CI workflow (format check, tests,
  build, benchmarks) run on pushes and pull requests.
- `.c3fmt` — formatter configuration for `c3fmt`.
- `lib/` — configured C3 dependency search directory; currently no dependency
  is vendored there. The Makefile creates the directory before C3 build/test
  commands if it is absent.
