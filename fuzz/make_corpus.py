"""Generate the deterministic honggfuzz seed corpus for c3_allocs.

Each output file is a byte stream where every 8 bytes (little-endian)
is one draw for the harness RNG in fuzz/fuzz_common.c3:

- roll draw: op = r % 100 (acquire <55, release <85, resize <93,
  hostile <96, audit otherwise)
- size draw: r % 32 == 0 -> 0; r % 4 == 0 -> uniform 1 + next % 256;
  otherwise EDGES[r % 24]
- align draw: r % 50 == 0 -> 3 (invalid); otherwise
  ALIGNS[r % 7] = [0, 0, 8, 16, 16, 32, 64]

The same stream feeds all seven allocator scenarios, each restarting
from byte zero, so every file exercises every allocator.

Usage: make_corpus.py <outdir> [--check <fuzz_hf-binary>]
--check runs each file through the harness and requires exit 0.
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


def motif(roll, size_edge=None, align_idx=None, extra=()):
    """One op: roll draw + size draw + align draw + trailing draws."""
    draws = [roll]
    if size_edge is None:
        draws.append(7)  # EDGES[7] == 16
    elif isinstance(size_edge, int):
        draws.extend(size_draws(size_edge))
    else:
        draws.extend(size_edge)  # raw draw list, e.g. uniform [4, v]
    draws.append(2 if align_idx is None else align_idx)  # ALIGNS[2] == 8
    draws.extend(extra)
    return draws


ACQ_SMALL = motif(10, 7, 3)      # acquire 16 @16
ACQ_ODD = motif(20, 5, 2)        # acquire 9 @8 (odd size -> slack)
ACQ_BIG = motif(30, 21, 6)       # acquire 65 @64
ACQ_ZERO = motif(40, 0, 2)        # acquire 0 -> must fail cleanly
ACQ_INVALIGN = motif(41, 7, 0)    # align draw 0 -> invalid 3, must fail
RSZ = motif(88, 13, 3)            # resize to 25 @16


def guard_release(idx):
    return [60, idx, 100]  # release; guard draw 100 % 100 == 0 probes guard


def hostile(pick):
    return [94, pick]


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

    pre = ACQ_ODD * 60  # size 9 leaves canary slack, so probes fire
    guard_ops = []
    for i in range(200):
        guard_ops += guard_release(i % 8)
    files["guard-probes"] = b"".join(u64(v) for v in pre + guard_ops)

    hostile_ops = []
    for i in range(120):
        hostile_ops += hostile(i % 4)
    files["hostile"] = b"".join(u64(v) for v in pre + hostile_ops)

    files["resize-heavy"] = b"".join(u64(v) for v in pre + RSZ * 120)

    sweep = list(ACQ_SMALL) * 40
    for roll in range(100):
        sweep += motif(roll, 9, 4)  # size 24 @32 through every branch
    files["rolls-sweep"] = b"".join(u64(v) for v in sweep)

    sizes = []
    for i in range(24):
        sizes += motif(10, i, 2)
    sizes += motif(10, 0, 2)  # zero-size acquire
    files["sizes-sweep"] = b"".join(u64(v) for v in sizes * 2)

    aligns = []
    for j in range(7):
        aligns += motif(10, 9, j)  # size 24, every alignment class
    aligns += motif(10, 9, 0)  # invalid alignment 3
    files["aligns-sweep"] = b"".join(u64(v) for v in aligns * 8)

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
