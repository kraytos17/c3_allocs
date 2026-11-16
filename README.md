# c3_allocs

Project-local memory allocators written in [C3](https://c3-lang.org/). The
allocators implement C3's `std::core::mem::alloc::Allocator` interface, so they
can be used with the standard allocation helpers without modifying the
installed C3 standard library.

> **Project status:** early development. The fixed-buffer arena is currently
> implemented; other allocator types may be added as the project grows.

## Requirements

- The C3 compiler (`c3c`). The project currently targets C3 language revision 1.
- `c3fmt` is optional and only needed to check formatting.

## Build and test

From the repository root:

```sh
make             # Build the executable
make test        # Run the test suite
make run         # Build and run the executable
make fmt-check   # Check C3 formatting without editing files
make fmt         # Format C3 files in place
make check       # Run formatting check, tests, and build
make clean       # Remove build artifacts
```

The executable and intermediate build files are written under `build/`. The
Makefile uses `c3c` and `c3fmt` from `PATH` by default; override them if needed,
for example `make C3C=/path/to/c3c test`. `make fmt` formats files in place;
review the resulting changes before committing them.

## Arena allocator

`c3_allocs::allocators::ArenaAllocator` allocates from a fixed-size buffer
provided by the caller. It is useful when many allocations share a lifetime and
can all be reclaimed together.

```c3
import std::core::mem::alloc;
import c3_allocs::allocators;

char[4096] storage;
allocators::ArenaAllocator arena;
arena.init(storage[..]);

char* bytes = alloc::malloc(&arena, 128);
// Use bytes while storage and arena remain alive.
alloc::free(&arena, bytes);

arena.clear(); // Invalidates every allocation from the arena.
```

### Arena behavior and constraints

- The arena **borrows** the supplied buffer. The buffer must outlive the arena
  and every pointer allocated from it.
- Allocations honor valid C3 alignments. Passing alignment `0` selects the
  default alignment.
- The arena has fixed capacity. Allocation fails when the buffer has no room;
  it does not allocate additional backing storage.
- `release` reclaims storage only when releasing the most recent allocation.
  Releasing an earlier allocation has no effect. Use marks and `reset`, or use
  `clear`, to reclaim groups of allocations.
- `resize` preserves the common prefix of the allocation. The most recent
  allocation is resized in place when it meets the requested alignment and
  there is enough capacity. Otherwise, the arena attempts to allocate a new
  block and copy the contents. If that fails, the old allocation remains valid
  and the arena state is unchanged. A full arena cannot move its most recent
  allocation elsewhere while also guaranteeing the original remains valid on
  failure.
- Direct zero-sized allocations are rejected. The standard `alloc` helpers
  handle zero-sized requests according to their own API behavior.
- The arena is not thread-safe. `reset` and `clear` invalidate allocations but
  do not run destructors for values stored in the buffer.

### Mark and reset

Save a position before a group of temporary allocations, then reset to it when
that group is no longer needed:

```c3
sz mark = arena.mark();
char* temporary = alloc::malloc(&arena, 256);
// Use temporary within this scope.
arena.reset(mark); // Invalidates allocations made after mark.
```

Do not use pointers to allocations after the arena has been reset or cleared.

## Project layout

- `src/` — allocator implementations and executable entry point.
- `test/` — allocator tests.
- `lib/` — project-local C3 dependencies.
- `.c3fmt` — repository formatting preferences for `c3fmt`.
