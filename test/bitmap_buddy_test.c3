module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void bitmap_buddy_carves_region_and_metadata() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	assert(buddy.capacity() > 0);
	assert(allocators::allocator_is_pow2(buddy.capacity()));
	assert(buddy.capacity() < 4096); // Metadata carved from the region.
	assert(buddy.bytes_free() == buddy.capacity());
	assert(buddy.bytes_used() == 0);
	assert(buddy.free_block_count() >= 1);
	assert(buddy.largest_free() > 0);
}

fn void bitmap_buddy_allocates_and_coalesces() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	void* a = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	void* b = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	assert(a != b);
	assert(buddy.bytes_free() < initial_free);
	buddy.release(a, false);
	buddy.release(b, false);
	assert(buddy.bytes_free() == initial_free);
	assert(buddy.free_block_count() >= 1);
	assert(buddy.largest_free() == buddy.capacity());
	void* big = buddy.acquire(buddy.capacity(), alloc::AllocInitType.NO_ZERO)!!;
	buddy.release(big, false);
	assert(buddy.bytes_free() == initial_free);
}

fn void bitmap_buddy_sixteen_byte_requests_use_full_blocks() @test
{
	char[1024] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_used = buddy.bytes_used();

	// Headerless: a 16-byte request consumes exactly one leaf block.
	void* p = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	assert(buddy.bytes_used() - initial_used == 16);
	buddy.release(p, false);
	assert(buddy.bytes_used() == initial_used);
}

fn void bitmap_buddy_honors_alignment_and_zeroing() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);

	char* data = buddy.acquire(32, alloc::AllocInitType.ZERO, 64)!!;
	assert(mem::ptr_is_aligned(data, 64));
	for (sz i = 0; i < 32; i++) assert(data[i] == 0);
}

fn void bitmap_buddy_rejects_invalid_and_reports_oom() @test
{
	char[1024] storage;
	allocators::BitmapBuddyAllocator buddy;
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
		return;
	}
	assert(false, "Expected invalid alignment to fail.");
}

fn void bitmap_buddy_rejects_oversize_requests() @test
{
	char[1024] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	sz free_before = buddy.bytes_free();

	void*? too_big = buddy.acquire(buddy.capacity() + 1, alloc::AllocInitType.NO_ZERO);
	if (catch too_big)
	{
		assert(buddy.bytes_free() == free_before);
		return;
	}
	assert(false, "Expected oversize acquisition to fail.");
}

fn void bitmap_buddy_ignores_foreign_and_duplicate_release() @test
{
	char[1024] storage;
	allocators::BitmapBuddyAllocator buddy;
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

fn void bitmap_buddy_owns_rejects_interior_and_foreign() @test
{
	char[1024] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);

	void* item = buddy.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	assert(buddy.owns(item));
	assert(!buddy.owns((char*)item + 4));
	assert(!buddy.owns((void*)0x1));
	buddy.release(item, false);
	assert(!buddy.owns(item));
}

fn void bitmap_buddy_resize_shrinks_in_place() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);

	char* original = buddy.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 64; i++) original[i] = (char)(i + 5);
	char* shrunk = buddy.resize(original, 24)!!;
	assert(shrunk == original);
	for (sz i = 0; i < 24; i++) assert(shrunk[i] == (char)(i + 5));
	assert(buddy.bytes_free() > 0);
	buddy.release(shrunk, false);
}

fn void bitmap_buddy_resize_moves_and_preserves_prefix() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);

	char* original = buddy.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 32; i++) original[i] = (char)(i + 9);
	char* grown = buddy.resize(original, 300)!!;
	assert(grown != original);
	for (sz i = 0; i < 32; i++) assert(grown[i] == (char)(i + 9));
	buddy.release(grown, false);
}

fn void bitmap_buddy_failed_resize_preserves_original() @test
{
	char[1024] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);

	char* original = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) original[i] = (char)(i + 3);
	sz free_before = buddy.bytes_free();
	void*? failed = buddy.resize(original, buddy.capacity() * 2, 0);
	if (catch failed)
	{
		assert(buddy.bytes_free() == free_before);
		for (sz i = 0; i < 16; i++) assert(original[i] == (char)(i + 3));
		return;
	}
	assert(false, "Expected oversize resize to fail.");
}

fn void bitmap_buddy_zero_capacity_when_buffer_too_small() @test
{
	char[16] storage;
	allocators::BitmapBuddyAllocator buddy;
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

fn void bitmap_buddy_clear_discards_all_allocations() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	(void)buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	(void)buddy.acquire(128, alloc::AllocInitType.NO_ZERO)!!;
	assert(buddy.bytes_free() < initial_free);
	buddy.clear();
	assert(buddy.bytes_free() == initial_free);
	void* after = buddy.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	assert(after != null);
}

fn void bitmap_buddy_works_with_standard_helpers() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);

	char* data = alloc::malloc(&buddy, 48);
	for (sz i = 0; i < 48; i++) data[i] = (char)i;
	char* grown = alloc::realloc(&buddy, data, 96);
	for (sz i = 0; i < 48; i++) assert(grown[i] == (char)i);
	alloc::free(&buddy, grown);
}

fn void bitmap_buddy_pressure_storm_restores_free_bytes() @test
{
	char[8192] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	ulong state = 0x5DEECE66D;
	void*[64] live = { };
	sz live_count = 0;
	for (sz op = 0; op < 1500; op++)
	{
		state ^= state << 13;
		state ^= state >> 7;
		state ^= state << 17;
		ulong roll = (ulong)state % 100;
		if (roll < 55 && live_count < 64)
		{
			state ^= state << 13;
			state ^= state >> 7;
			state ^= state << 17;
			sz size = 1 + (sz)((ulong)state % 512);
			void*? ptr_opt = buddy.acquire(size, alloc::AllocInitType.NO_ZERO);
			if (catch ptr_opt) continue;
			live[live_count] = ptr_opt;
			live_count++;
		}
		else if (live_count > 0)
		{
			state ^= state << 13;
			state ^= state >> 7;
			state ^= state << 17;
			sz idx = (sz)((ulong)state % (ulong)live_count);
			buddy.release(live[idx], false);
			live[idx] = live[live_count - 1];
			live_count--;
		}
		assert(buddy.bytes_free() <= initial_free);
	}
	for (sz i = 0; i < live_count; i++) buddy.release(live[i], false);
	assert(buddy.bytes_free() == initial_free);
	assert(buddy.largest_free() == buddy.capacity());
}

fn void bitmap_buddy_shrink_keeps_free_list_intact() @test
{
	char[4096] storage;
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	char* original = buddy.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 64; i++) original[i] = (char)(i + 5);
	char* shrunk = buddy.resize(original, 24)!!;
	assert(shrunk == original);
	// The shrink publishes right-hand buddies into the released tail.
	// Poisoning must happen before publishing, or the fresh links are
	// clobbered and the next walk follows garbage.
	assert(buddy.debug_verify());
	buddy.release(shrunk, false);
	assert(buddy.debug_verify());
	assert(buddy.bytes_free() == initial_free);
	assert(buddy.free_block_count() == 1);
}
