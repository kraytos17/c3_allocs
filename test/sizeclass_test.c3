module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void sizeclass_routes_to_smallest_fitting_class() @test
{
	char[512] s0;
	char[512] s1;
	char[512] s2;
	char[][3] bufs = { s0[..], s1[..], s2[..] };
	sz[3] sizes = { 32, 96, 256 };
	allocators::SizeClassAllocator sc;
	sc.init(bufs[..], sizes[..]);
	assert(sc.class_count() == 3);
	assert(sc.class_block_size(0) == 32);
	assert(sc.class_block_size(1) == 96);
	assert(sc.class_block_size(2) == 256);
	assert(sc.capacity() > 0);
	assert(sc.available() == sc.capacity());

	sz avail0 = sc.class_available(0);
	sz avail1 = sc.class_available(1);
	sz avail2 = sc.class_available(2);
	void* small = sc.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	assert(sc.class_available(0) == avail0 - 1);
	assert(sc.class_available(1) == avail1);
	assert(sc.class_available(2) == avail2);
	void* medium = sc.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(sc.class_available(1) == avail1 - 1);
	void* large = sc.acquire(200, alloc::AllocInitType.NO_ZERO)!!;
	assert(sc.class_available(2) == avail2 - 1);
	sc.release(small, false);
	sc.release(medium, false);
	sc.release(large, false);
	assert(sc.available() == sc.capacity());
}

fn void sizeclass_rejects_oversize_and_bad_alignment() @test
{
	char[256] s0;
	char[256] s1;
	char[][2] bufs = { s0[..], s1[..] };
	sz[2] sizes = { 32, 96 };
	allocators::SizeClassAllocator sc;
	sc.init(bufs[..], sizes[..]);
	sz free_before = sc.available();

	void*? too_big = sc.acquire(1024, alloc::AllocInitType.NO_ZERO);
	if (catch too_big)
	{
		assert(sc.available() == free_before);
	}
	else
	{
		assert(false, "Expected oversize request to be rejected.");
	}
	void*? bad_align = sc.acquire(8, alloc::AllocInitType.NO_ZERO, 3);
	if (catch bad_align)
	{
		assert(sc.available() == free_before);
	}
	else
	{
		assert(false, "Expected invalid alignment to be rejected.");
	}
}

fn void sizeclass_reports_out_of_memory_when_fitting_class_full() @test
{
	char[512] s0;
	char[512] s1;
	char[][2] bufs = { s0[..], s1[..] };
	sz[2] sizes = { 32, 512 };
	allocators::SizeClassAllocator sc;
	sc.init(bufs[..], sizes[..]);

	sz small_slots = sc.class_available(0);
	for (sz i = 0; i < small_slots; i++)
	{
		(void)sc.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	}
	sz free_before = sc.available();
	void*? failed = sc.acquire(16, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		assert(sc.available() == free_before);
		return;
	}
	assert(false, "Expected a full class to report out of memory.");
}

fn void sizeclass_resize_stays_in_owning_class() @test
{
	char[512] s0;
	char[512] s1;
	char[][2] bufs = { s0[..], s1[..] };
	sz[2] sizes = { 32, 128 };
	allocators::SizeClassAllocator sc;
	sc.init(bufs[..], sizes[..]);

	char* item = sc.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) item[i] = (char)(i + 1);
	char* grown = sc.resize(item, 24)!!;
	assert(grown == item);
	for (sz i = 0; i < 16; i++) assert(grown[i] == (char)(i + 1));
	sz free_before = sc.available();
	void*? failed = sc.resize(item, 64, 0);
	if (catch failed)
	{
		assert(sc.available() == free_before);
		for (sz i = 0; i < 16; i++) assert(item[i] == (char)(i + 1));
		sc.release(item, false);
		assert(sc.available() == free_before + 1);
		return;
	}
	assert(false, "Expected resize beyond the class size to fail.");
}

fn void sizeclass_ignores_foreign_release() @test
{
	char[256] s0;
	char[][1] bufs = { s0[..] };
	sz[1] sizes = { 32 };
	allocators::SizeClassAllocator sc;
	sc.init(bufs[..], sizes[..]);

	void* item = sc.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	sz used = sc.available();
	sc.release((void*)0x1, false);
	assert(sc.available() == used);
	sc.release(item, false);
	assert(sc.available() == used + 1);
	sc.release(item, false);
	assert(sc.available() == used + 1);
}

fn void sizeclass_preset_uses_stepped_table() @test
{
	char[5120] storage;
	allocators::SizeClassAllocator sc;
	sc.init_preset(storage[..], 5);
	assert(sc.class_count() == 5);
	assert(sc.class_block_size(0) == 24);
	assert(sc.class_block_size(1) == 48);
	assert(sc.class_block_size(2) == 96);
	assert(sc.class_block_size(3) == 192);
	assert(sc.class_block_size(4) == 384);
	assert(sc.class_available(0) > 0);
	assert(sc.class_available(4) > 0);

	void* small = sc.acquire(20, alloc::AllocInitType.NO_ZERO)!!;
	void* big = sc.acquire(300, alloc::AllocInitType.NO_ZERO)!!;
	assert(small != null && big != null);
	sc.release(small, false);
	sc.release(big, false);
	assert(sc.available() == sc.capacity());
}

fn void sizeclass_preset_smaller_counts_cover_larger_requests() @test
{
	char[1024] storage;
	allocators::SizeClassAllocator sc;
	sc.init_preset(storage[..], 3);
	assert(sc.class_count() == 3);
	assert(sc.class_block_size(2) == 96);
	void* item = sc.acquire(80, alloc::AllocInitType.NO_ZERO)!!;
	assert(item != null);
	sc.release(item, false);
	void*? failed = sc.acquire(200, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		return;
	}
	assert(false, "Expected requests beyond the largest preset class to fail.");
}
