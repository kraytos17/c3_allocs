# c3_allocs

`c3_allocs` is a C3 project for experimenting with memory allocators that
implement the standard library's `std::core::mem::alloc::Allocator` interface.

## Current status

The repository currently contains one allocator:

- **`ArenaAllocator`** — a fixed-capacity arena backed by a caller-provided
  byte slice. It supports alignment, zero-initialized allocation, resize,
  last-allocation release, and mark/reset bulk reclamation.

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
block and arena state. If the newest block cannot grow in place, the arena
cannot move it elsewhere within the same fixed buffer while guaranteeing the
original stays valid on failure, so that resize fails instead.

### Limitations

- The arena is not thread-safe; synchronize access externally if sharing it.
- Resetting or clearing invalidates pointers into reclaimed storage.
- Values that require cleanup are not automatically destroyed when storage is
  released or reset. Arrange any required cleanup before invalidating their
  storage.

## Repository layout

- `src/allocators/arena.c3` — the arena implementation.
- `src/main.c3` — executable entry point.
- `test/arena_test.c3` — arena behavior and failure-path tests.
- `project.json` — C3 compiler project configuration.
- `Makefile` — build, test, formatting, and clean targets.
- `.c3fmt` — formatter configuration for `c3fmt`.
- `lib/` — configured C3 dependency search directory; currently no dependency
  is vendored there. The Makefile creates the directory before C3 build/test
  commands if it is absent.
