# c3_allocs

`c3_allocs` is a C3 project for experimenting with memory allocators that
implement the standard library's `std::core::mem::alloc::Allocator` interface.

## Current status

The repository currently contains four allocators:

- **`ArenaAllocator`** — a fixed-capacity arena backed by a caller-provided
  byte slice. It supports alignment, zero-initialized allocation, resize,
  last-allocation release, and mark/reset bulk reclamation.
- **`PoolAllocator`** — a fixed-capacity pool that divides caller-provided
  storage into equal-sized slots and reuses individual slots after release.
- **`BackedArenaAllocator`** — an arena that starts in a caller-provided buffer
  and obtains individual overflow blocks from a backing allocator. It supports
  marks and frees overflow blocks when resetting to an earlier mark.
- **`FreeListAllocator`** — a variable-size allocator over caller-provided
  storage. It uses first-fit selection, splits on allocate, and coalesces
  neighbours on release. It supports in-place shrink and growth into an
  adjacent free range, otherwise it moves on resize.

## Requirements

- The C3 compiler, `c3c`, with support for language revision 1.
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
make fmt-check   # Check C3 formatting without changing files
make fmt         # Format C3 files in place
make check       # Run fmt-check, test, and build in sequence
make clean       # Remove C3 build artifacts
```

`make all` is an alias for `make build`. Build outputs are written under
`build/`. The `make fmt` target edits files in `src/` and `test/`; review its
changes before committing them. Formatting rules are in the root `.c3fmt` file.

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
  slot count and `available()` reports the current free-slot count.
- Requests larger than the configured payload size, with unsupported
  alignment, or after all slots are in use fail without consuming a slot.
- `release` makes a valid slot available for reuse. Null, foreign, interior,
  and duplicate-release pointers are ignored.
- `resize` stays in the same slot and can only change the requested size up to
  the configured payload size. It never moves or grows the slot.
- The pool is not thread-safe and does not run destructors for values stored
  in its memory.

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
- `release` frees overflow blocks immediately. For allocations inside the
  initial buffer, only a last-in-first-out release sequence reclaims space.
- `resize` preserves the common prefix. It may resize the newest initial-buffer
  allocation in place; otherwise it acquires a replacement before releasing
  the old allocation. On failure, it leaves the original allocation valid.
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
- `capacity()` reports the borrowed length, `bytes_free()` reports free
  ranges, and `bytes_used()` reports borrowed bytes not currently free.
  `largest_free()` reports the biggest contiguous range and
  `free_block_count()` reports how many ranges exist.
- `acquire` aligns payloads, supports `ZERO` init, and leaves state unchanged
  on failure. A range is split only when the remainder can hold a free node.
- `release` ignores null, foreign, interior, and duplicate releases, then
  coalesces with adjacent free neighbours.
- `resize` preserves the prefix. It shrinks in place, grows into an adjacent
  free range when possible, otherwise moves. Failure preserves the original.
- The allocator is not thread-safe and does not run destructors.

### Shared core and typed helpers

- `src/allocators/common.c3` holds the shared alignment, padding,
  effective-alignment, range, and split helpers used by all allocators.
  They are public so custom allocators can reuse them; file-local helpers
  stay `@local`.
- Use the standard `alloc::new` / `alloc::new_try` macros for typed
  allocation; they derive size and alignment from the type. For pools, use
  `pool_init_for{Type}(&pool, storage[..])` to size slots from a type.

## Repository layout

- `src/allocators/common.c3` — shared alignment helpers.
- `src/allocators/arena.c3` — the arena implementation.
- `src/allocators/pool.c3` — the fixed-slot pool implementation.
- `src/allocators/backed_arena.c3` — the arena with backing-allocator overflow.
- `src/allocators/freelist.c3` — the variable-size free-list implementation.
- `src/main.c3` — executable entry point.
- `test/arena_test.c3`, `test/pool_test.c3`, `test/backed_arena_test.c3`,
  and `test/freelist_test.c3` — allocator behavior and failure-path tests.
- `project.json` — C3 compiler project configuration.
- `Makefile` — build, test, formatting, and clean targets.
- `.c3fmt` — formatter configuration for `c3fmt`.
- `lib/` — configured C3 dependency search directory; currently no dependency
  is vendored there. The Makefile creates the directory before C3 build/test
  commands if it is absent.
