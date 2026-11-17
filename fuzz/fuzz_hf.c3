module c3_allocs::fuzz_hf;

import std::core::mem;
import std::core::mem::alloc;
import std::io;
import std::io::file;
import c3_allocs::allocators;
import c3_allocs::fuzz_common;

const HF_DEFAULT_ITERATIONS = 2000;
const HF_DEFAULT_MAXLIVE = 64;
const HF_PERSISTENT_ITERATIONS = 500;
const HF_PERSISTENT_MAXLIVE = 64;
const HF_INPUT_CAP = 65536;

extern fn CInt honggfuzz_main(CInt argc, char** argv) @cname("HonggfuzzMain");
extern fn void abort();

fn CInt fuzz_test_one_input(char* buf, usz len) @cname("c3_fuzz_one_input") @nostrip
{
	// The libhfuzz buffer is only valid for this call, so copy it into a
	// bounded stack buffer with a plain byte loop (its alignment is not
	// guaranteed, which mem::copy requires).
	char[HF_INPUT_CAP] input;
	usz capped = len < (usz)HF_INPUT_CAP ? len : (usz)HF_INPUT_CAP;
	sz n = (sz)capped;
	for (sz i = 0; i < n; i++) input[i] = buf[i];

	usz mask;
	FuzzRng base = fuzz_common::fuzz_rng_hf_stream(1, input[:n], &mask);

	char[16384] freelist_storage;
	char[8192] pool_storage;
	char[16384] buddy_storage;
	char[16384] bitmap_storage;
	char[8192] class_storage;
	char[4096] backed_initial;
	char[65536] backed_backing;
	char[8192] scratch_storage;
	char[8192] arena_storage;
	char[16384] tracking_storage;

	int failures = 0;
	int rc;
	if (mask == 9 || mask == 0)
	{
		rc = fuzz_common::fuzz_freelist(freelist_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	if (mask == 9 || mask == 1)
	{
		rc = fuzz_common::fuzz_pool(pool_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	if (mask == 9 || mask == 2)
	{
		rc = fuzz_common::fuzz_buddy(buddy_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	if (mask == 9 || mask == 3)
	{
		rc = fuzz_common::fuzz_bitmap_buddy(bitmap_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	if (mask == 9 || mask == 4)
	{
		rc = fuzz_common::fuzz_sizeclass(class_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	if (mask == 9 || mask == 5)
	{
		rc = fuzz_common::fuzz_backed_arena(
			backed_initial[..],
			backed_backing[..],
			base,
			HF_PERSISTENT_ITERATIONS,
			HF_PERSISTENT_MAXLIVE
		);
		failures += rc;
	}
	if (mask == 9 || mask == 6)
	{
		rc = fuzz_common::fuzz_scratch(scratch_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	if (mask == 9 || mask == 7)
	{
		rc = fuzz_common::fuzz_arena(arena_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	if (mask == 9 || mask == 8)
	{
		rc = fuzz_common::fuzz_tracking(tracking_storage[..], base, HF_PERSISTENT_ITERATIONS, HF_PERSISTENT_MAXLIVE);
		failures += rc;
	}
	// A nonzero return would only make libhfuzz exit(1): not counted as a
	// crash and the input is not saved. Abort instead so the failure is
	// recorded as a crash with its input.
	if (failures == 0) return 0;

	abort();
	return 1;
}

fn int fuzz_hf_file(String path, sz iterations, sz max_live)
{
	char[]? data_opt = file::load_temp(path);
	if (catch data_opt)
	{
		io::printf("cannot read input %s\n", path);
		return 2;
	}

	char[] data = data_opt;
	FuzzRng base = fuzz_common::fuzz_rng_stream(1, data);
	io::printf("fuzz_hf: bytes=%d iterations=%d max_live=%d\n", data.len, iterations, max_live);

	char[16384] freelist_storage;
	char[8192] pool_storage;
	char[16384] buddy_storage;
	char[16384] bitmap_storage;
	char[8192] class_storage;
	char[4096] backed_initial;
	char[65536] backed_backing;
	char[8192] scratch_storage;
	char[8192] arena_storage;
	char[16384] tracking_storage;

	int failures = 0;
	int rc = fuzz_common::fuzz_freelist(freelist_storage[..], base, iterations, max_live);
	io::printf("freelist: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_pool(pool_storage[..], base, iterations, max_live);
	io::printf("pool: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_buddy(buddy_storage[..], base, iterations, max_live);
	io::printf("buddy: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_bitmap_buddy(bitmap_storage[..], base, iterations, max_live);
	io::printf("bitmap: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_sizeclass(class_storage[..], base, iterations, max_live);
	io::printf("sizeclass: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_backed_arena(backed_initial[..], backed_backing[..], base, iterations, max_live);
	io::printf("backed: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_scratch(scratch_storage[..], base, iterations, max_live);
	io::printf("scratch: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_arena(arena_storage[..], base, iterations, max_live);
	io::printf("arena: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;

	rc = fuzz_common::fuzz_tracking(tracking_storage[..], base, iterations, max_live);
	io::printf("tracking: %s\n", rc == 0 ? "PASS" : "FAIL");
	failures += rc;
	if (failures == 0)
	{
		io::printn("fuzz_hf: ALL PASS");
	}
	else
	{
		io::printf("fuzz_hf: %d FAILURES\n", failures);
	}
	return failures == 0 ? 0 : 1;
}

fn int main(String[] args)
{
	// With a file argument, run that input directly (corpus validation,
	// triage). Otherwise delegate to libhfuzz: persistent loop under
	// honggfuzz, single stdin input standalone.
	if (args.len >= 2)
	{
		sz iterations = (sz)fuzz_common::fuzz_arg(args, 2, (ulong)HF_DEFAULT_ITERATIONS);
		sz max_live = (sz)fuzz_common::fuzz_arg(args, 3, (ulong)HF_DEFAULT_MAXLIVE);
		if (iterations <= 0) iterations = HF_DEFAULT_ITERATIONS;
		if (max_live <= 0 || max_live > fuzz_common::FUZZ_MAXLIVE) max_live = HF_DEFAULT_MAXLIVE;
		return fuzz_hf_file(args[1], iterations, max_live);
	}

	// libhfuzz logs argv[0] even in stdin mode, so pass a real program name.
	char[8] prog = { 'f', 'u', 'z', 'z', '_', 'h', 'f', 0 };
	char* argv0 = &prog[0];
	return honggfuzz_main(1, &argv0);
}
