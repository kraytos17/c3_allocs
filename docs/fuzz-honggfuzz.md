# Honggfuzz setup

This project fuzzes its allocators with
[honggfuzz](https://github.com/google/honggfuzz)
on top of the deterministic seeded harness in `fuzz/`.

## Prereqs

- `clang` on `PATH`.
- A honggfuzz binary: `make fuzz-hf-deps` uses one from `PATH` or builds
  it into `build/honggfuzz` (git-ignored; override the root with
  `make fuzz-hf HF_DIR=/path/to/honggfuzz`). Building needs `clang`,
  libunwind, binutils.
- Linux with `kernel.perf_event_paranoid <= 1` so honggfuzz gets hardware
  feedback: `cat /proc/sys/kernel/perf_event_paranoid`. This box runs at 1.

Pinned working build: honggfuzz `01713bd` (Nov 2026), c3c 0.8.7 prerelease.

## How it works

`fuzz/fuzz_common.c3` holds the nine allocator scenarios (freelist,
pool, buddy, bitmap buddy, size class, backed arena, scratch, arena,
tracking). Each draws randomness from `FuzzRng`: with no input bytes it
degrades to xorshift (the `make fuzz` smoke path); `fuzz/fuzz_hf.c3`
loads honggfuzz's input file and each draw consumes 8 input bytes
before falling back to xorshift. Same scenarios, same oracles
(`debug_verify`, canary sampling, slot/byte accounting, guard
validation, positional-reset filtering, final restore) — only the
randomness source changes. The first input draw selects one scenario
(0-8) or all of them (9), so corpus files can focus on one allocator;
an empty input runs everything.

`make fuzz-hf` builds the harness in **persistent mode** (the default):
`LLVMFuzzerTestOneInput` is defined in C3 and forwarded through the
tiny C shim in `fuzz/hf_shim.c` (a shim is needed because c3c
currently emits `@cname` functions as weak symbols, which would lose
to libhfuzz's weak default stub; the C3 side is kept alive with
`@nostrip`). Our `main` delegates to libhfuzz's `HonggfuzzMain`, so the
same binary runs persistent under honggfuzz (`-P`, no `___FILE___`
placeholder), reads stdin standalone, and still takes a file path for
corpus validation and triage. With no file argument the binary runs its
input once and exits; oracle failures call `abort()` because libhfuzz's
own failure path is only `exit(1)`, which honggfuzz would not record as
a crash. Measured throughput here is ~5000 execs/s vs ~400/s for the
old spawn-per-input mode.

The harness builds with `c3c -O2 --sanitize=address`, so memory errors
are crashes honggfuzz records, while logic violations abort via the
existing oracles.

## Commands

```sh
make fuzz-hf-deps    # check for honggfuzz + clang
make fuzz-hf-corpus  # regenerate seed corpus in fuzz/corpus
make fuzz-hf         # bounded session, plain ASan build (see below)
make fuzz-hf-cov     # bounded session, clang coverage build
make fuzz-hf HF_N=100000 HF_TIMEOUT=30 HF_THREADS=4
```

`fuzz/make_corpus.py` builds the corpus deterministically from the
draw encoding in `fuzz/fuzz_common.c3`: op = draw % 100 (freelist map
is acquire <55, release <85, resize <90, hostile <93, policy toggle
<95, clear <97, else audit; other allocators have their own maps),
size = edge table / uniform / zero, alignment (with invalid 3),
init ZERO vs NO_ZERO, plus the leading mask draw. Files cover op
sweeps across all branches, size and alignment sweeps, ZERO-init runs,
canary-guard probes, hostile releases, policy toggles, bulk clears,
mark/reset/prune windows, OOM fills, empty/tiny inputs, adversarial
constants, per-scenario mask files, and uniform blobs.
`python3 fuzz/make_corpus.py fuzz/corpus --check ./out/fuzz_hf`
regenerates and validates every file against the harness.

Defaults: `HF_N=20000` iterations, `HF_TIMEOUT=10`s per input,
`HF_THREADS=2`. `make fuzz-hf` links the plain c3c/ASan binary, which
honggfuzz drives blind (hardware tracing yields no usable signal on
the tested machines: 500k blind inputs found zero new units). `make
fuzz-hf-cov` instead emits LLVM IR (`--emit-llvm`), compiles it with
`clang -fsanitize-coverage=trace-pc-guard`, and links libhfuzz: the
same harness then reports real branch coverage (25% on the seed
corpus, ~600 new units in a 2M-input session) while keeping ASan. Prefer
`-cov` for any serious session; the plain target stays as the fast
smoke that needs no extra toolchain steps.
`fuzz/corpus/` is git-ignored and fully regenerative:
`make fuzz-hf-corpus` recreates the deterministic seeds (fixed PRNG)
and `make fuzz-hf` regenerates them automatically when missing.
New coverage lands in `out/hf_new` (git-ignored); crash inputs land as
`*.fuzz` files in the working directory (also git-ignored) — copy the
crashing input aside before rerunning.

## Triage

1. Reproduce: `./out/fuzz_hf <crashing-input>` prints
   `FUZZ FAIL seed=… <allocator> op=…` plus the 64-op ring log.
2. Minimize with honggfuzz (`-M`), then convert the op stream into a
   fixed regression test in `test/hardening_test.c3`.
3. Fix, rerun `make check`, `make fuzz`, and the crashing input.
