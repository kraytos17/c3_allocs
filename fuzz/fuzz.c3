module c3_allocs::fuzz;

import std::core::mem;
import std::core::mem::alloc;
import std::io;
import c3_allocs::allocators;
import c3_allocs::fuzz_common;

fn int main(String[] args)
{
	ulong seed = fuzz_common::fuzz_arg(args, 1, (ulong)fuzz_common::FUZZ_DEFAULT_SEED);
	fuzz_common::FuzzRng base = fuzz_common::fuzz_rng_seed(seed);
	sz iterations = (sz)fuzz_common::fuzz_arg(args, 2, (ulong)fuzz_common::FUZZ_DEFAULT_ITERATIONS);
	sz max_live = (sz)fuzz_common::fuzz_arg(args, 3, (ulong)fuzz_common::FUZZ_DEFAULT_MAXLIVE);
	if (max_live > fuzz_common::FUZZ_MAXLIVE) max_live = fuzz_common::FUZZ_MAXLIVE;
	if (iterations <= 0) iterations = fuzz_common::FUZZ_DEFAULT_ITERATIONS;

	io::printf("fuzz: seed=%d iterations=%d max_live=%d\n", (sz)seed, iterations, max_live);

	char[16384] freelist_storage;
	char[8192] pool_storage;
	char[16384] buddy_storage;
	char[16384] bitmap_storage;
	char[8192] class_storage;
	char[4096] backed_initial;
	char[65536] backed_backing;
	char[8192] scratch_storage;

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
	if (failures == 0)
	{
		io::printn("fuzz: ALL PASS");
	}
	else
	{
		io::printf("fuzz: %d FAILURES\n", failures);
	}
	return failures == 0 ? 0 : 1;
}
