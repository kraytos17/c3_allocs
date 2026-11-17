"""Generate the deterministic honggfuzz seed corpus for c3_allocs.

Each output file is a byte stream where every 8 bytes (little-endian)
is one draw for the harness RNG in fuzz/fuzz_common.c3:

- roll draw: op = r % 100. Freelist map: <55 acquire, <85 release,
  <90 resize, <93 hostile, <95 policy toggle, <97 clear, else audit.
  Other allocators have their own maps (same draw, same idea).
- size draw: r % 32 == 0 -> 0; r % 4 == 0 -> uniform 1 + next % 256;
  otherwise EDGES[r % 24].
- align draw: r % 50 == 0 -> 3 (invalid); otherwise
  ALIGNS[r % 7] = [0, 0, 8, 16, 16, 32, 64].
- init draw: r % 3 == 0 -> ZERO, otherwise NO_ZERO.
- mask draw (honggfuzz entry only): first u64 % 10 selects one of the
  9 scenarios (0 freelist, 1 pool, 2 buddy, 3 bitmap, 4 sizeclass,
  5 backed, 6 scratch, 7 arena, 8 tracking) or all of them (9).

The same stream feeds every scenario, each restarting from byte zero
(except the mask draw, consumed once up front). Deterministic: fixed
PRNG seed, and `make_corpus.py --check` validates every file against
the harness (exit 0 expected).

Usage: make_corpus.py <outdir> [--check <fuzz_hf-binary>]
"""

import random
import struct
import subprocess
import sys
from pathlib import Path

PRNG_SEED = 0xC3A110C5

EDGES = [0, 1, 2, 7, 8, 9, 15, 16, 17, 23, 24, 25,
         31, 32, 33, 47, 48, 49, 63, 64, 65, 100, 128, 200]
ALIGNS = [0, 0, 8, 16, 16, 32, 64]


def u64(v):
    return struct.pack("<Q", v & 0xFFFFFFFFFFFFFFFF)


def size_draws(edge_idx):
    """Draws forcing fuzz_size to yield EDGES[edge_idx]."""
    if edge_idx == 0:
        return [32]  # r % 32 == 0 -> 0
    if edge_idx % 4 != 0:
        return [edge_idx]  # r % 4 != 0, r % 24 == edge_idx
    return [4, EDGES[edge_idx] - 1]  # uniform path: 1 + (v - 1)


def motif(roll, size_edge=9, align_idx=2, init=1, extra=()):
    """One generic op: roll + size + align + init + trailing draws."""
    draws = [roll]
    if isinstance(size_edge, int):
        draws.extend(size_draws(size_edge))
    else:
        draws.extend(size_edge)
    draws.append(align_idx)
    draws.append(init)
    draws.extend(extra)
    return draws


ACQ_SMALL = motif(10, 7, 3)      # acquire 16 @16, NO_ZERO
ACQ_ODD = motif(20, 5, 2)        # acquire 9 @8 (odd size -> slack)
ACQ_BIG = motif(30, 21, 6)       # acquire 65 @64
ACQ_ZERO = motif(40, 7, 3)       # acquire 16 @16
ACQ_ZERO[-1] = 0                 # ... with ZERO init
ACQ_INVALIGN = motif(41, 7, 0)   # invalid alignment 3 -> must fail
RSZ = motif(88, 13, 3)            # resize to 25 @16
POL = [94, 0]                    # policy flip to FIRST_FIT
POL_BEST = [94, 1]               # policy flip to BEST_FIT
CLR = [96]                       # bulk clear op


def guard_release(idx):
    return [60, idx, 100]  # release; guard draw 100 % 100 == 0 probes guard


def build_files(rng):
    files = {}
    files["empty"] = b""

    base_stream = b"".join(u64(v) for v in ACQ_SMALL * 4)
    for n, name in [(1, "tiny-1"), (7, "tiny-7"), (8, "tiny-8"),
                    (15, "tiny-15"), (16, "tiny-16"), (24, "tiny-24")]:
        files[name] = base_stream[:n]

    files["acquire-fill"] = b"".join(u64(v) for v in ACQ_SMALL * 80)
    mixed = (ACQ_SMALL + ACQ_ODD + ACQ_BIG + ACQ_ZERO + ACQ_INVALIGN) * 24
    files["acquire-mixed"] = b"".join(u64(v) for v in mixed)
    files["zero-init"] = b"".join(u64(v) for v in ACQ_ZERO * 60)

    pre = ACQ_ODD * 60
    guard_ops = []
    for i in range(200):
        guard_ops += guard_release(i % 8)
    files["guard-probes"] = b"".join(u64(v) for v in pre + guard_ops)

    hostile_ops = []
    for i in range(120):
        hostile_ops += [91, i % 6]
    files["hostile"] = b"".join(u64(v) for v in [0] + pre + hostile_ops)

    pacq = [10] + size_draws(9)
    phostile = []
    for _ in range(100):
        phostile += [97]
    files["pool-hostile"] = b"".join(u64(v) for v in [1] + pacq * 60 + phostile)

    files["resize-heavy"] = b"".join(u64(v) for v in pre + RSZ * 120)

    files["policy-toggle"] = b"".join(
        u64(v) for v in [0] + ACQ_SMALL * 40 + (POL + POL_BEST) * 30)
    files["clear-heavy"] = b"".join(
        u64(v) for v in [0] + (ACQ_SMALL * 20 + CLR) * 8)

    sweep = list(ACQ_SMALL) * 40
    for roll in range(100):
        sweep += motif(roll, 9, 4)
    files["rolls-sweep"] = b"".join(u64(v) for v in sweep)

    sizes = []
    for i in range(24):
        sizes += motif(10, i, 2)
    sizes += motif(10, 0, 2)
    files["sizes-sweep"] = b"".join(u64(v) for v in sizes * 2)

    aligns = []
    for j in range(7):
        aligns += motif(10, 9, j)
    aligns += motif(10, 9, 0)
    files["aligns-sweep"] = b"".join(u64(v) for v in aligns * 8)

    # Backed-arena positional machinery: mark / reset-retaining / prune.
    bpre = []
    for _ in range(40):
        bpre += motif(10, 9, 2)
    bops = []
    for i in range(100):
        bops += [87, i % 3]
    files["reset-heavy"] = b"".join(u64(v) for v in [5] + bpre + bops)

    # Arena mark/reset windows.
    apre = []
    for _ in range(40):
        apre += motif(10, 9, 2)
    aops = []
    for i in range(100):
        aops += [82, i % 2]
    for _ in range(10):
        aops += [90]
    files["arena-mark"] = b"".join(u64(v) for v in [7] + apre + aops)

    # One focused file per scenario (mask = first draw).
    body = list(ACQ_SMALL) * 40
    for roll in range(100):
        body += motif(roll, 9, 4)
    for k in range(10):
        files[f"mask-{k}"] = b"".join(u64(v) for v in [k] + body)

    for name, nbytes in [("uniform-4k", 4096), ("uniform-16k", 16384),
                         ("uniform-64k", 65536)]:
        files[name] = rng.randbytes(nbytes)

    files["zeros-4k"] = b"\x00" * 4096
    files["ones-4k"] = b"\xff" * 4096
    files["alt-aa55-4k"] = b"\xaa\x55" * 2048
    files["counter-4k"] = b"".join(u64(i) for i in range(512))

    files["oom-big"] = b"".join(u64(v) for v in ACQ_BIG * 300)
    return files


def main():
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("fuzz/corpus")
    check = None
    if "--check" in sys.argv:
        check = sys.argv[sys.argv.index("--check") + 1]
    outdir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(PRNG_SEED)
    files = build_files(rng)
    for name, data in sorted(files.items()):
        (outdir / name).write_bytes(data)
        print(f"{name}: {len(data)} bytes")
    print(f"wrote {len(files)} files to {outdir}")
    if check:
        bad = 0
        for name in sorted(files):
            rc = subprocess.run([check, str(outdir / name)],  # noqa: PLW1510
                                capture_output=True).returncode
            status = "ok" if rc == 0 else f"FAIL({rc})"
            if rc != 0:
                bad += 1
            print(f"check {name}: {status}")
        if bad:
            print(f"{bad} corpus files fail the harness")
            return 1
        print("all corpus files pass the harness")
    return 0


if __name__ == "__main__":
    sys.exit(main())
