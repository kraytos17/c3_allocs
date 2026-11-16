module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void backed_arena_uses_initial_buffer_then_backing_allocator() @test
{
	char[128] initial_storage;
	char[1024] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	char* first = arena.acquire(16, alloc::AllocInitType.ZERO)!!;
	for (sz i = 0; i < 16; i++) assert(first[i] == 0);
	sz initial_mark = arena.mark();
	char* overflow = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(overflow != first);
	assert(backing.available() < backing.capacity());
	for (sz i = 0; i < 16; i++) first[i] = (char)(i + 1);
	for (sz i = 0; i < 64; i++) overflow[i] = (char)(0x40 + i);

	arena.reset(initial_mark);
	assert(backing.available() == backing.capacity());
	for (sz i = 0; i < 16; i++) assert(first[i] == (char)(i + 1));
}

fn void backed_arena_reset_frees_only_pages_after_mark() @test
{
	char[16] initial_storage;
	char[1024] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	void* first_page = arena.acquire(48, alloc::AllocInitType.NO_ZERO)!!;
	sz mark = arena.mark();
	void* second_page = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	sz available_with_two_pages = backing.available();
	assert(available_with_two_pages < backing.capacity());

	arena.reset(mark);
	assert(backing.available() > available_with_two_pages);
	assert(arena.mark() == mark);

	void* replacement_page = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(replacement_page != first_page);
	assert(second_page != first_page);
	assert(replacement_page == second_page);
	arena.clear();
	assert(backing.available() == backing.capacity());
	assert(arena.mark() == 0);
}

fn void backed_arena_release_reclaims_latest_initial_allocation() @test
{
	char[128] initial_storage;
	char[512] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	void* first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz before_second = arena.initial_used;
	void* second = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	arena.release(second, false);
	assert(arena.initial_used == before_second);
	arena.release(first, false);
	assert(arena.initial_used == 0);
}

fn void backed_arena_release_frees_overflow_block() @test
{
	char[8] initial_storage;
	char[512] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	void* overflow = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	sz available_before_free = backing.available();
	assert(available_before_free < backing.capacity());
	arena.release(overflow, false);
	assert(backing.available() == backing.capacity());
}

fn void backed_arena_resize_preserves_prefix_across_growth() @test
{
	char[16] initial_storage;
	char[1024] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	char* original = arena.acquire(48, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 48; i++) original[i] = (char)(i + 1);
	char* grown = arena.resize(original, 96)!!;
	assert(grown != original);
	for (sz i = 0; i < 48; i++) assert(grown[i] == (char)(i + 1));

	char* shrunk = arena.resize(grown, 32)!!;
	assert(shrunk == grown);
	for (sz i = 0; i < 32; i++) assert(shrunk[i] == (char)(i + 1));
	arena.free();
	assert(backing.available() == backing.capacity());
}

fn void backed_arena_aligned_overflow_works_with_helpers() @test
{
	char[16] initial_storage;
	char[1024] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	void* aligned = alloc::malloc_aligned(&arena, 80, 64)!!;
	assert(mem::ptr_is_aligned(aligned, 64));
	assert(backing.available() < backing.capacity());
	alloc::free_aligned(&arena, aligned);
	assert(backing.available() == backing.capacity());
}

fn void backed_arena_failed_overflow_keeps_state_unchanged() @test
{
	char[8] initial_storage;
	char[64] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 32, 16);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	sz mark = arena.mark();
	sz initial_used = arena.initial_used;
	sz backing_available = backing.available();
	void*? failed = arena.acquire(256, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		assert(arena.mark() == mark);
		assert(arena.initial_used == initial_used);
		assert(backing.available() == backing_available);
		return;
	}
	assert(false, "Expected overflow allocation to fail with an exhausted backing allocator.");
}

fn void backed_arena_invalid_requests_do_not_mutate_state() @test
{
	char[64] initial_storage;
	char[256] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	sz mark = arena.mark();
	void*? zero = arena.acquire(0, alloc::AllocInitType.NO_ZERO);
	if (catch zero)
	{
		assert(arena.mark() == mark);
	}
	else
	{
		assert(false, "Expected zero-size allocation to be rejected.");
	}
	void*? invalid_alignment = arena.acquire(8, alloc::AllocInitType.NO_ZERO, 3);
	if (catch invalid_alignment)
	{
		assert(arena.mark() == mark);
		return;
	}
	assert(false, "Expected invalid alignment to be rejected.");
}

fn void backed_arena_ignores_foreign_and_duplicate_release() @test
{
	char[128] initial_storage;
	char[512] backing_storage;
	allocators::PoolAllocator backing;
	backing.init(backing_storage[..], 256, 64);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing);

	void* first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* overflow = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	sz backing_available = backing.available();
	arena.release(&backing_storage[0], false);
	assert(backing.available() == backing_available);
	arena.release(overflow, false);
	assert(backing.available() == backing.capacity());
	arena.release(overflow, false);
	assert(backing.available() == backing.capacity());
	assert(first != overflow);
}
