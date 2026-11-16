module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void freelist_allocates_variable_sizes() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	assert(list.capacity() == 512);
	sz initial_free = list.bytes_free();
	assert(initial_free > 0);
	assert(list.bytes_used() == list.capacity() - initial_free);

	void* first = list.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	void* second = list.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	void* third = list.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	assert(first != second && first != third && second != third);
	assert(list.bytes_free() < initial_free);
	assert(list.bytes_used() > 0);
}

fn void freelist_honors_alignment_and_zeroing() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* data = list.acquire(32, alloc::AllocInitType.ZERO, 64)!!;
	assert(mem::ptr_is_aligned(data, 64));
	for (sz i = 0; i < 32; i++) assert(data[i] == 0);
}

fn void freelist_release_reuses_and_coalesces() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	void* a = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	void* b = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	void* c = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	sz used_three = list.bytes_used();
	list.release(b, false);
	assert(list.bytes_free() > initial_free - used_three);
	void* reused = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	assert(list.bytes_used() == used_three);
	list.release(a, false);
	list.release(reused, false);
	list.release(c, false);
	assert(list.bytes_free() == initial_free);
	(void)a;
	(void)c;
}

fn void freelist_full_coalescing_restores_single_range() @test
{
	char[256] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	void* a = list.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	void* b = list.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	void* c = list.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	list.release(b, false);
	list.release(a, false);
	list.release(c, false);
	assert(list.bytes_free() == initial_free);
	void* big = list.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(big != null);
	list.release(big, false);
	assert(list.bytes_free() == initial_free);
}

fn void freelist_middle_release_merges_both_neighbours() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	void* a = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	void* b = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	void* c = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	list.release(a, false);
	list.release(c, false);
	assert(list.bytes_free() < initial_free);
	list.release(b, false);
	assert(list.bytes_free() == initial_free);
	void* big = list.acquire(96, alloc::AllocInitType.NO_ZERO)!!;
	assert(big != null);
	list.release(big, false);
	assert(list.bytes_free() == initial_free);
}

fn void freelist_rejects_invalid_requests_without_state_change() @test
{
	char[256] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz free_before = list.bytes_free();

	void*? zero = list.acquire(0, alloc::AllocInitType.NO_ZERO);
	if (catch zero)
	{
		assert(list.bytes_free() == free_before);
	}
	else
	{
		assert(false, "Expected zero-size acquisition to fail.");
	}
	void*? bad_align = list.acquire(8, alloc::AllocInitType.NO_ZERO, 3);
	if (catch bad_align)
	{
		assert(list.bytes_free() == free_before);
	}
	else
	{
		assert(false, "Expected invalid alignment to fail.");
	}
}

fn void freelist_returns_out_of_memory_when_full() @test
{
	char[128] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz free_before = list.bytes_free();

	void*? first = list.acquire(1024, alloc::AllocInitType.NO_ZERO);
	if (catch first)
	{
		assert(list.bytes_free() == free_before);
		return;
	}
	assert(false, "Expected oversize acquisition to fail.");
}

fn void freelist_ignores_foreign_and_duplicate_release() @test
{
	char[256] storage;
	char[256] other_storage;
	allocators::FreeListAllocator list;
	allocators::FreeListAllocator other;
	list.init(storage[..]);
	other.init(other_storage[..]);

	void* item = list.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	sz used = list.bytes_used();
	void* foreign = other.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	list.release(foreign, false);
	assert(list.bytes_used() == used);
	list.release((void*)0x1, false);
	assert(list.bytes_used() == used);
	list.release(item, false);
	sz after_release = list.bytes_used();
	list.release(item, false);
	assert(list.bytes_used() == after_release);
	list.release(foreign, false);
	other.release(foreign, false);
}

fn void freelist_resize_shrink_and_grow_in_place() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* original = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 32; i++) original[i] = (char)(i + 1);
	char* grown = list.resize(original, 48)!!;
	for (sz i = 0; i < 32; i++) assert(grown[i] == (char)(i + 1));
	char* shrunk = list.resize(grown, 16)!!;
	assert(shrunk == grown);
	for (sz i = 0; i < 16; i++) assert(shrunk[i] == (char)(i + 1));
}

fn void freelist_resize_grows_into_adjacent_free_range() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* first = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 32; i++) first[i] = (char)(0x30 + i);
	void* second = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	list.release(second, false);
	char* grown = list.resize(first, 64)!!;
	assert(grown == first);
	for (sz i = 0; i < 32; i++) assert(grown[i] == (char)(0x30 + i));
}

fn void freelist_resize_moves_and_preserves_prefix() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* first = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 32; i++) first[i] = (char)(i + 5);
	void* blocker = list.acquire(128, alloc::AllocInitType.NO_ZERO)!!;
	char* moved = list.resize(first, 96)!!;
	assert(moved != first);
	for (sz i = 0; i < 32; i++) assert(moved[i] == (char)(i + 5));
	list.release(moved, false);
	list.release(blocker, false);
}

fn void freelist_failed_resize_preserves_original() @test
{
	char[128] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* original = list.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 16; i++) original[i] = (char)(i + 9);
	sz free_before = list.bytes_free();
	void*? failed = list.resize(original, 1024, 0);
	if (catch failed)
	{
		assert(list.bytes_free() == free_before);
		for (sz i = 0; i < 16; i++) assert(original[i] == (char)(i + 9));
		return;
	}
	assert(false, "Expected oversize resize to fail.");
}

fn void freelist_resize_with_stricter_alignment_moves_safely() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* original = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 32; i++) original[i] = (char)(i ^ 0x5A);
	char* resized = list.resize(original, 48, 64)!!;
	assert(mem::ptr_is_aligned(resized, 64));
	for (sz i = 0; i < 32; i++) assert(resized[i] == (char)(i ^ 0x5A));
}

fn void freelist_clear_discards_all_allocations() @test
{
	char[256] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	(void)list.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	(void)list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	assert(list.bytes_free() < initial_free);
	list.clear();
	assert(list.bytes_free() == initial_free);
	void* after = list.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	assert(after != null);
}

fn void freelist_zero_capacity_when_buffer_too_small() @test
{
	char[1] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	assert(list.bytes_free() == 0);
	void*? failed = list.acquire(1, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		return;
	}
	assert(false, "Expected allocation to fail with a tiny buffer.");
}

fn void freelist_works_with_standard_allocation_helpers() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* data = alloc::malloc(&list, 48);
	for (sz i = 0; i < 48; i++) data[i] = (char)i;
	char* grown = alloc::realloc(&list, data, 96);
	for (sz i = 0; i < 48; i++) assert(grown[i] == (char)i);
	alloc::free(&list, grown);
}
