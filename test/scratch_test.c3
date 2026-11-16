module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void scratch_tracks_peak_and_clears_per_frame() @test
{
	char[256] storage;
	allocators::ScratchAllocator scratch;
	scratch.init(storage[..]);
	assert(scratch.capacity() == 256);
	assert(scratch.bytes_reserved() == 0);
	assert(scratch.peak() == 0);

	(void)scratch.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	sz after_first = scratch.bytes_reserved();
	assert(scratch.peak() == after_first);
	(void)scratch.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	assert(scratch.peak() == scratch.bytes_reserved());
	assert(scratch.peak() >= after_first);

	scratch.clear();
	assert(scratch.bytes_reserved() == 0);
	sz peak_before = scratch.peak();
	assert(peak_before > 0);
	(void)scratch.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	assert(scratch.peak() == peak_before);
	scratch.reset_peak();
	assert(scratch.peak() == scratch.bytes_reserved());
}

fn void scratch_release_reclaims_only_latest() @test
{
	char[256] storage;
	allocators::ScratchAllocator scratch;
	scratch.init(storage[..]);

	void* first = scratch.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	void* second = scratch.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	sz both = scratch.bytes_reserved();
	scratch.release(first, false);
	assert(scratch.bytes_reserved() == both);
	scratch.release(second, false);
	assert(scratch.bytes_reserved() < both);
	scratch.release(first, false);
	assert(scratch.bytes_reserved() == 0);
}

fn void scratch_mark_reset_and_resize() @test
{
	char[256] storage;
	allocators::ScratchAllocator scratch;
	scratch.init(storage[..]);

	char* item = scratch.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) item[i] = (char)(i + 7);
	sz mark = scratch.mark();
	(void)scratch.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	scratch.reset(mark);
	assert(scratch.bytes_reserved() == mark);
	char* grown = scratch.resize(item, 32)!!;
	assert(grown == item);
	for (sz i = 0; i < 16; i++) assert(grown[i] == (char)(i + 7));
}

fn void scratch_works_with_standard_helpers() @test
{
	char[256] storage;
	allocators::ScratchAllocator scratch;
	scratch.init(storage[..]);

	char* data = alloc::malloc(&scratch, 24);
	for (sz i = 0; i < 24; i++) data[i] = (char)i;
	char* grown = alloc::realloc(&scratch, data, 48);
	for (sz i = 0; i < 24; i++) assert(grown[i] == (char)i);
	alloc::free(&scratch, grown);
	assert(scratch.bytes_reserved() == 0);
}
