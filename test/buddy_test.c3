module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void buddy_carves_pow2_region_from_buffer() @test
{
	char[512] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);
	assert(buddy.capacity() > 0);
	assert(allocators::allocator_is_pow2(buddy.capacity()));
	assert(buddy.capacity() <= 512);
	assert(buddy.bytes_free() == buddy.capacity());
	assert(buddy.bytes_used() == 0);
	assert(buddy.free_block_count() == 1);
	assert(buddy.largest_free() == buddy.capacity());
}

fn void buddy_allocates_and_coalesces() @test
{
	char[1024] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	void* a = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	void* b = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	assert(a != b);
	assert(buddy.bytes_free() < initial_free);
	assert(buddy.free_block_count() >= 1);
	buddy.release(a, false);
	buddy.release(b, false);
	assert(buddy.bytes_free() == initial_free);
	assert(buddy.free_block_count() == 1);
	assert(buddy.largest_free() == buddy.capacity());
	void* big = buddy.acquire(128, alloc::AllocInitType.NO_ZERO)!!;
	assert(big != null);
	buddy.release(big, false);
	assert(buddy.bytes_free() == initial_free);
}

fn void buddy_honors_alignment_and_zeroing() @test
{
	char[1024] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	char* data = buddy.acquire(32, alloc::AllocInitType.ZERO, 64)!!;
	assert(mem::ptr_is_aligned(data, 64));
	for (sz i = 0; i < 32; i++) assert(data[i] == 0);
}

fn void buddy_rejects_invalid_and_reports_oom() @test
{
	char[256] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);
	sz free_before = buddy.bytes_free();

	void*? zero = buddy.acquire(0, alloc::AllocInitType.NO_ZERO);
	if (catch zero)
	{
		assert(buddy.bytes_free() == free_before);
	}
	else
	{
		assert(false, "Expected zero-size acquisition to fail.");
	}
	void*? bad_align = buddy.acquire(8, alloc::AllocInitType.NO_ZERO, 3);
	if (catch bad_align)
	{
		assert(buddy.bytes_free() == free_before);
	}
	else
	{
		assert(false, "Expected invalid alignment to fail.");
	}
	void*? too_big = buddy.acquire(buddy.capacity() + 1, alloc::AllocInitType.NO_ZERO);
	if (catch too_big)
	{
		assert(buddy.bytes_free() == free_before);
		return;
	}
	assert(false, "Expected oversize acquisition to fail.");
}

fn void buddy_ignores_foreign_and_duplicate_release() @test
{
	char[512] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	void* item = buddy.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	sz used = buddy.bytes_used();
	buddy.release((void*)0x1, false);
	assert(buddy.bytes_used() == used);
	buddy.release(item, false);
	assert(buddy.bytes_used() < used);
	sz after_release = buddy.bytes_used();
	buddy.release(item, false);
	assert(buddy.bytes_used() == after_release);
}

fn void buddy_resize_shrinks_in_place_and_grows_by_move() @test
{
	char[1024] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	char* original = buddy.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 32; i++) original[i] = (char)(i + 2);
	char* shrunk = buddy.resize(original, 16)!!;
	assert(shrunk == original);
	for (sz i = 0; i < 16; i++) assert(shrunk[i] == (char)(i + 2));
	char* grown = buddy.resize(shrunk, 200)!!;
	for (sz i = 0; i < 16; i++) assert(grown[i] == (char)(i + 2));
	buddy.release(grown, false);
}

fn void buddy_failed_resize_preserves_original() @test
{
	char[256] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	char* original = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) original[i] = (char)(i + 3);
	sz free_before = buddy.bytes_free();
	void*? failed = buddy.resize(original, 4096, 0);
	if (catch failed)
	{
		assert(buddy.bytes_free() == free_before);
		for (sz i = 0; i < 16; i++) assert(original[i] == (char)(i + 3));
		return;
	}
	assert(false, "Expected oversize resize to fail.");
}

fn void buddy_zero_capacity_when_buffer_too_small() @test
{
	char[16] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);
	assert(buddy.capacity() == 0);
	assert(buddy.bytes_free() == 0);
	assert(buddy.largest_free() == 0);
	void*? failed = buddy.acquire(1, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		return;
	}
	assert(false, "Expected allocation to fail with a tiny buffer.");
}

fn void buddy_clear_discards_all_allocations() @test
{
	char[512] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	(void)buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	(void)buddy.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(buddy.bytes_free() < initial_free);
	buddy.clear();
	assert(buddy.bytes_free() == initial_free);
	assert(buddy.free_block_count() == 1);
}

fn void buddy_works_with_standard_helpers() @test
{
	char[1024] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	char* data = alloc::malloc(&buddy, 48);
	for (sz i = 0; i < 48; i++) data[i] = (char)i;
	char* grown = alloc::realloc(&buddy, data, 96);
	for (sz i = 0; i < 48; i++) assert(grown[i] == (char)i);
	alloc::free(&buddy, grown);
}

fn void buddy_owns_rejects_interior_and_foreign() @test
{
	char[512] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	void* item = buddy.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	assert(buddy.owns(item));
	assert(!buddy.owns((char*)item + 4));
	assert(!buddy.owns((void*)0x1));
	buddy.release(item, false);
	assert(!buddy.owns(item));
}
