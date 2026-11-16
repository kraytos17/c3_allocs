module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void arena_allocates_and_releases_latest() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	void* first = arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	void* second = arena.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	assert(first != second);
	sz used_with_both = arena.used;

	arena.release(second, false);
	assert(arena.used < used_with_both);
	arena.release(first, false);
	assert(arena.used == 0);
}

fn void arena_honors_alignment_and_zeroing() @test
{
	char[256] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* data = arena.acquire(32, alloc::AllocInitType.ZERO, 64)!!;
	assert(mem::ptr_is_aligned(data, 64));
	for (sz i = 0; i < 32; i++) assert(data[i] == 0);
}

fn void arena_resize_preserves_data() @test
{
	char[256] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* original = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 8; i++) original[i] = (char)(i + 1);
	char* resized = arena.resize(original, 32, 0)!!;
	for (sz i = 0; i < 8; i++) assert(resized[i] == (char)(i + 1));
}

fn void arena_mark_reset_and_clear() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	(void)arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	sz mark = arena.mark();
	(void)arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	arena.reset(mark);
	assert(arena.used == mark);
	arena.clear();
	assert(arena.used == 0);
}

fn void arena_works_through_allocator_helpers() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	void* data = alloc::malloc(&arena, 24);
	assert(data != null);
	alloc::free(&arena, data);
	assert(arena.used == 0);
}

fn void arena_failed_allocation_preserves_state() @test
{
	char[64] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz used_before_failure = arena.used;
	void*? failed = arena.acquire(128, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		assert(arena.used == used_before_failure);
		return;
	}
	assert(false, "Expected allocation to fail when the arena is full.");
}

fn void arena_resize_last_in_place_grow_and_shrink() @test
{
	char[256] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* original = arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) original[i] = (char)(0x20 + i);
	sz before = arena.used;
	char* grown = arena.resize(original, 48, 0)!!;
	assert(grown == original);
	assert(arena.used == before + 32);
	for (sz i = 0; i < 16; i++) assert(grown[i] == (char)(0x20 + i));

	char* shrunk = arena.resize(grown, 8, 0)!!;
	assert(shrunk == grown);
	assert(arena.used < before);
	for (sz i = 0; i < 8; i++) assert(shrunk[i] == (char)(0x20 + i));
}

fn void arena_resize_failure_keeps_last_allocation_valid() @test
{
	char[64] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* original = arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) original[i] = (char)(i + 1);
	sz used_before = arena.used;
	void*? failed = arena.resize(original, 256, 0);
	if (catch failed)
	{
		assert(arena.used == used_before);
		for (sz i = 0; i < 16; i++) assert(original[i] == (char)(i + 1));
		return;
	}
	assert(false, "Expected resize to fail when the arena has no capacity.");
}

fn void arena_resize_non_last_moves_and_preserves_prefix() @test
{
	char[256] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* first = arena.acquire(12, alloc::AllocInitType.NO_ZERO)!!;
	char* second = arena.acquire(12, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 12; i++) first[i] = (char)(i + 5);
	char* moved = arena.resize(first, 32, 0)!!;
	assert(moved != first);
	for (sz i = 0; i < 12; i++) assert(moved[i] == (char)(i + 5));
	assert(second != moved);
}

fn void arena_resize_non_last_failure_keeps_old_allocation() @test
{
	char[80] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* first = arena.acquire(12, alloc::AllocInitType.NO_ZERO)!!;
	(void)arena.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 12; i++) first[i] = (char)(0x40 + i);
	sz used_before = arena.used;
	void*? failed = arena.resize(first, 80, 0);
	if (catch failed)
	{
		assert(arena.used == used_before);
		for (sz i = 0; i < 12; i++) assert(first[i] == (char)(0x40 + i));
		return;
	}
	assert(false, "Expected non-last resize to fail when no room remains.");
}

fn void arena_resize_honors_new_alignment() @test
{
	char[256] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* original = arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) original[i] = (char)(i + 9);
	char* resized = arena.resize(original, 32, 64)!!;
	assert(mem::ptr_is_aligned(resized, 64));
	for (sz i = 0; i < 16; i++) assert(resized[i] == (char)(i + 9));
}

fn void arena_non_last_release_does_not_reclaim_space() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	void* first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* second = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz used_with_both = arena.used;
	arena.release(first, false);
	assert(arena.used == used_with_both);
	arena.release(second, false);
	assert(arena.used > 0);
}

fn void arena_rejects_invalid_alignment_without_state_change() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);
	sz before = arena.used;
	void*? bad_alignment = arena.acquire(8, alloc::AllocInitType.NO_ZERO, 3);
	if (catch bad_alignment)
	{
		assert(arena.used == before);
		return;
	}
	assert(false, "Expected non-power-of-two alignment to be rejected.");
}

fn void arena_supports_offset_buffer_and_over_alignment() @test
{
	char[129] storage;
	char[] offset_storage = storage[1..];
	allocators::ArenaAllocator arena;
	arena.init(offset_storage);

	char* data = arena.acquire(1, alloc::AllocInitType.NO_ZERO, 64)!!;
	assert(mem::ptr_is_aligned(data, 64));
}

fn void arena_realloc_zero_size_frees_via_helper() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);
	void* ptr = alloc::malloc(&arena, 16);
	assert(arena.used > 0);
	void* resized = alloc::realloc(&arena, ptr, 0);
	assert(resized == null);
	assert(arena.used == 0);
}

fn void arena_aligned_helpers_release_correctly() @test
{
	char[256] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);
	void* ptr = alloc::malloc_aligned(&arena, 32, 64)!!;
	assert(mem::ptr_is_aligned(ptr, 64));
	alloc::free_aligned(&arena, ptr);
	assert(arena.used == 0);
}

fn void arena_rejects_zero_size_and_max_alignment() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);
	sz used_before = arena.used;
	void*? zero_size = arena.acquire(0, alloc::AllocInitType.NO_ZERO);
	if (catch zero_size)
	{
		assert(arena.used == used_before);
	}
	else
	{
		assert(false, "Expected zero-sized direct allocation to fail.");
	}
	void*? too_much_alignment = arena.acquire(8, alloc::AllocInitType.NO_ZERO, mem::MAX_MEMORY_ALIGNMENT);
	if (catch too_much_alignment)
	{
		assert(arena.used == used_before);
		return;
	}
	assert(false, "Expected the maximum unsupported alignment to fail.");
}

fn void arena_rejects_negative_sizes_without_state_change() @test
{
	char[128] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);
	sz used_before = arena.used;
	void*? negative_alloc = arena.acquire(-1, alloc::AllocInitType.NO_ZERO);
	if (catch negative_alloc)
	{
		assert(arena.used == used_before);
	}
	else
	{
		assert(false, "Expected negative allocation size to be rejected.");
	}
	void* valid = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz after_valid = arena.used;
	void*? negative_resize = arena.resize(valid, -1, 0);
	if (catch negative_resize)
	{
		assert(arena.used == after_valid);
		return;
	}
	assert(false, "Expected negative resize size to be rejected.");
}

fn void arena_stress_exhaust_and_reset_cycles() @test
{
	char[512] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	for (sz cycle = 0; cycle < 20; cycle++)
	{
		sz allocations = 0;
		for (sz i = 0; i < 128; i++)
		{
			sz alignment = (sz)1 << (i % 6);
			void*? result = arena.acquire(7 + (i % 5), alloc::AllocInitType.NO_ZERO, alignment);
			if (catch result) break;
			assert(mem::ptr_is_aligned(result, alignment));
			allocations++;
		}
		assert(allocations > 0);
		assert(arena.used <= arena.data.len);
		arena.clear();
		assert(arena.used == 0);
	}
}

fn void arena_exact_fit_uses_final_buffer_byte() @test
{
	char[64] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	// Discover the amount consumed by one byte, then reset before exact-fit checks.
	(void)arena.acquire(1, alloc::AllocInitType.NO_ZERO)!!;
	sz overhead = arena.used - 1;
	arena.clear();

	void* exact = arena.acquire(storage.len - overhead, alloc::AllocInitType.NO_ZERO)!!;
	assert(exact != null);
	assert(arena.used == storage.len);

	void*? extra = arena.acquire(1, alloc::AllocInitType.NO_ZERO);
	if (catch extra)
	{
		assert(arena.used == storage.len);
		return;
	}
	assert(false, "Expected allocation beyond exact arena capacity to fail.");
}

fn void arena_last_resize_alignment_failure_preserves_original() @test
{
	char[64] storage;
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	char* original = arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) original[i] = (char)(i + 0x30);
	sz used_before = arena.used;

	// The buffer is deliberately too small for moving this final block to a
	// separate 64-byte-aligned location while preserving the original on failure.
	void*? failed = arena.resize(original, 80, 64);
	if (catch failed)
	{
		assert(arena.used == used_before);
		for (sz i = 0; i < 16; i++) assert(original[i] == (char)(i + 0x30));
		return;
	}
	assert(false, "Expected stricter-alignment resize to fail without moving the last block.");
}
