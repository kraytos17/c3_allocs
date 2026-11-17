module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void backed_arena_uses_initial_buffer_then_backing_allocator() @test
{
	char[128] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* first = arena.acquire(16, alloc::AllocInitType.ZERO)!!;
	for (sz i = 0; i < 16; i++) assert(first[i] == 0);
	sz initial_mark = arena.mark();
	char* overflow = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(overflow != first);
	assert(arena.overflow_count() > 0);
	for (sz i = 0; i < 16; i++) first[i] = (char)(i + 1);
	for (sz i = 0; i < 64; i++) overflow[i] = (char)(0x40 + i);

	arena.reset(initial_mark);
	assert(arena.overflow_count() == 0);
	for (sz i = 0; i < 16; i++) assert(first[i] == (char)(i + 1));
}

fn void backed_arena_reset_frees_only_pages_after_mark() @test
{
	char[16] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* first_page = arena.acquire(256, alloc::AllocInitType.NO_ZERO)!!;
	sz mark = arena.mark();
	void* second_page = arena.acquire(320, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.overflow_count() == 2);

	arena.reset(mark);
	assert(arena.overflow_count() == 1);
	assert(arena.mark() == mark);

	void* replacement_page = arena.acquire(320, alloc::AllocInitType.NO_ZERO)!!;
	assert(replacement_page != first_page);
	assert(second_page != first_page);
	assert(replacement_page == second_page);
	arena.clear();
	assert(arena.overflow_count() == 0);
	assert(arena.mark() == 0);
}

fn void backed_arena_release_reclaims_latest_initial_allocation() @test
{
	char[128] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz before_second = arena.initial_bytes_reserved();
	void* second = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	arena.release(second, false);
	assert(arena.initial_bytes_reserved() == before_second);
	arena.release(first, false);
	assert(arena.initial_bytes_reserved() == 0);
}

fn void backed_arena_release_frees_overflow_block() @test
{
	char[8] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* overflow = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.overflow_count() > 0);
	arena.release(overflow, false);
	assert(arena.overflow_count() == 0);
}

fn void backed_arena_resize_preserves_prefix_across_growth() @test
{
	char[16] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* original = arena.acquire(48, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 48; i++) original[i] = (char)(i + 1);
	char* grown = arena.resize(original, 96)!!;
	assert(grown != original);
	for (sz i = 0; i < 48; i++) assert(grown[i] == (char)(i + 1));

	char* shrunk = arena.resize(grown, 32)!!;
	assert(shrunk == grown);
	for (sz i = 0; i < 32; i++) assert(shrunk[i] == (char)(i + 1));
	arena.free();
	assert(arena.overflow_count() == 0);
}

fn void backed_arena_aligned_overflow_works_with_helpers() @test
{
	char[16] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* aligned = alloc::malloc_aligned(&arena, 80, 64)!!;
	assert(mem::ptr_is_aligned(aligned, 64));
	assert(arena.overflow_count() > 0);
	alloc::free_aligned(&arena, aligned);
	assert(arena.overflow_count() == 0);
}

fn void backed_arena_failed_overflow_keeps_state_unchanged() @test
{
	char[8] initial_storage;
	Allocator backing = &std::core::mem::allocators::NULL_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	sz mark = arena.mark();
	sz initial_used = arena.initial_bytes_reserved();
	bool had_pages = arena.overflow_count() > 0;
	void*? failed = arena.acquire(256, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		assert(arena.mark() == mark);
		assert(arena.initial_bytes_reserved() == initial_used);
		assert((arena.overflow_count() > 0) == had_pages);
		return;
	}
	assert(false, "Expected overflow allocation to fail with an exhausted backing allocator.");
}

fn void backed_arena_invalid_requests_do_not_mutate_state() @test
{
	char[64] initial_storage;
	Allocator backing = &std::core::mem::allocators::NULL_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

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
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* overflow = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.overflow_count() > 0);
	arena.release((void*)0x1, false);
	assert(arena.overflow_count() > 0);
	arena.release(overflow, false);
	assert(arena.overflow_count() == 0);
	arena.release(overflow, false);
	assert(arena.overflow_count() == 0);
	assert(first != overflow);
}

fn void backed_arena_reset_mark_keeps_older_overflow_and_initial_allocations() @test
{
	char[512] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* initial = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	initial[0] = 0x31;
	void* page_before_mark = arena.acquire(1200, alloc::AllocInitType.NO_ZERO)!!;
	sz mark = arena.mark();
	void* page_after_mark = arena.acquire(1200, alloc::AllocInitType.NO_ZERO)!!;
	char* initial_after_mark = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	initial_after_mark[0] = 0x52;
	assert(arena.overflow_count() == 2);

	arena.reset(mark);
	assert(arena.overflow_count() == 1);
	assert(initial[0] == 0x31);
	assert(arena.initial_bytes_reserved() <= arena.bytes_used() + 64);

	void* replacement = arena.acquire(1200, alloc::AllocInitType.NO_ZERO)!!;
	assert(replacement != initial);
	assert(replacement != initial_after_mark);
	assert(arena.overflow_count() > 0);
	(void)page_after_mark;
	(void)page_before_mark;
	arena.clear();
	assert(arena.overflow_count() == 0);
}

fn void backed_arena_release_interleaved_allocations_reclaims_only_available_tops() @test
{
	char[64] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* initial_first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* overflow = arena.acquire(1200, alloc::AllocInitType.NO_ZERO)!!;
	sz initial_used_before_release = arena.initial_bytes_reserved();
	arena.release(initial_first, false);
	assert(arena.initial_bytes_reserved() == initial_used_before_release);
	arena.release(overflow, false);
	assert(arena.overflow_count() == 0);
	assert(arena.initial_bytes_reserved() == initial_used_before_release);
	(void)initial_first;
}

fn void backed_arena_reset_after_released_initial_tail_rewinds_chain() @test
{
	char[256] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz mark = arena.mark();
	void* tail = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz used_tail = arena.initial_bytes_reserved();
	arena.release(tail, false);
	assert(arena.initial_bytes_reserved() < used_tail);
	arena.reset(mark);
	assert(arena.initial_bytes_reserved() <= used_tail);
	assert(arena.mark() == mark);
}

fn void backed_arena_release_interleaved_initial_overflow_initial() @test
{
	char[1024] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* first_initial = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* second_initial = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* overflow = arena.acquire(1200, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.initial_bytes_reserved() > 0);

	// Overflow storage is released independently; the earlier initial allocation remains.
	arena.release(overflow, false);
	assert(arena.overflow_count() == 0);
	assert(arena.initial_bytes_reserved() > 0);
	arena.release(second_initial, false);
	assert(arena.initial_bytes_reserved() > 0);
	arena.release(first_initial, false);
	assert(arena.initial_bytes_reserved() == 0);
}

fn void backed_arena_release_initial_uses_lifo_order_to_reclaim_space() @test
{
	char[256] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void* first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* second = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz used_two = arena.initial_bytes_reserved();
	arena.release(first, false);
	assert(arena.initial_bytes_reserved() == used_two);
	arena.release(second, false);
	assert(arena.initial_bytes_reserved() == 0);
	assert(arena.mark() == 2);
}

fn void backed_arena_reset_rewinds_released_initial_tail_after_mark() @test
{
	char[256] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz mark = arena.mark();
	void* tail = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz tail_end = arena.initial_bytes_reserved();
	arena.release(tail, false);
	assert(arena.initial_bytes_reserved() < tail_end);
	sz used_after_release = arena.initial_bytes_reserved();
	arena.reset(mark);
	assert(arena.initial_bytes_reserved() <= used_after_release);
	assert(arena.mark() == mark);
}

fn void backed_arena_resize_initial_last_in_place_and_preserves_data() @test
{
	char[256] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* original = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 8; i++) original[i] = (char)(0x20 + i);
	char* grown = arena.resize(original, 24)!!;
	assert(grown == original);
	for (sz i = 0; i < 8; i++) assert(grown[i] == (char)(0x20 + i));
	assert(arena.initial_bytes_reserved() > 0);
}

fn void backed_arena_resize_initial_to_overflow_preserves_original_on_failure() @test
{
	char[256] initial_storage;
	Allocator backing = &std::core::mem::allocators::NULL_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* original = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 8; i++) original[i] = (char)(i + 1);
	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz initial_used = arena.initial_bytes_reserved();
	sz mark = arena.mark();
	void*? failed = arena.resize(original, 80, 0);
	if (catch failed)
	{
		assert(arena.initial_bytes_reserved() == initial_used);
		assert(arena.mark() == mark);
		for (sz i = 0; i < 8; i++) assert(original[i] == (char)(i + 1));
		return;
	}
	assert(false, "Expected resize to report failure without invalidating the old block.");
}

fn void backed_arena_resize_overflow_with_stricter_alignment_moves_safely() @test
{
	char[8] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* original = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 64; i++) original[i] = (char)(i ^ 0x5A);
	char* resized = arena.resize(original, 96, 64)!!;
	assert(mem::ptr_is_aligned(resized, 64));
	for (sz i = 0; i < 64; i++) assert(resized[i] == (char)(i ^ 0x5A));
}

fn void backed_arena_can_reuse_a_mark_after_reset() @test
{
	char[128] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz mark = arena.mark();
	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	arena.reset(mark);
	assert(arena.mark() == mark);
	(void)arena.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	arena.reset(mark);
	assert(arena.mark() == mark);
}

fn void backed_arena_nested_marks_reset_in_order() @test
{
	char[16] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	// The 16-byte buffer cannot hold headers, so every allocation overflows.
	char* first = arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	first[0] = 0x11;
	sz outer = arena.mark();
	char* middle = arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	middle[0] = 0x22;
	assert(arena.overflow_count() == 2);
	sz inner = arena.mark();
	char* latest = arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	latest[0] = 0x33;
	assert(arena.overflow_count() == 3);

	arena.reset(inner);
	assert(arena.mark() == inner);
	assert(arena.overflow_count() == 2);
	assert(middle[0] == 0x22);
	assert(first[0] == 0x11);
	arena.reset(outer);
	assert(arena.mark() == outer);
	assert(arena.overflow_count() == 1);
	assert(first[0] == 0x11);
	(void)latest;
}

fn void backed_arena_stale_mark_aliases_new_history_positionally() @test
{
	char[16] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* first = arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	first[0] = 0x41;
	sz mark = arena.mark();
	(void)arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	arena.reset(0);
	char* replacement = arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	replacement[0] = 0x42;
	(void)arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.overflow_count() == 2);
	arena.reset(mark);
	assert(arena.mark() == mark);
	assert(arena.overflow_count() == 1);
	assert(replacement[0] == 0x42);
	(void)first;
}

fn void backed_arena_mixed_initial_and_overflow_reset_keeps_older() @test
{
	char[256] initial_storage;
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	char* first = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	first[0] = 0x41;
	sz mark = arena.mark();
	void* big = arena.acquire(512, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.overflow_count() == 1);
	arena.reset(mark);
	assert(arena.overflow_count() == 0);
	assert(first[0] == 0x41);
	assert(arena.bytes_used() == 8);
	(void)big;
}

fn void backed_arena_failed_overflow_resize_preserves_old_block() @test
{
	char[8] initial_storage;
	Allocator backing = &std::core::mem::allocators::NULL_ALLOCATOR;
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], backing);

	void*? failed = arena.acquire(80, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		assert(arena.mark() == 0);
		assert(arena.overflow_count() == 0);
		return;
	}
	assert(false, "Expected overflow allocation to fail with a null backing allocator.");
}

fn void backed_arena_served_counts_track_paths() @test
{
	char[128] initial_storage;
	char[1024] backing_storage;
	allocators::ArenaAllocator backing_arena;
	backing_arena.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing_arena);
	assert(arena.initial_served() == 0);
	assert(arena.overflow_served() == 0);

	(void)arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.initial_served() == 1);
	assert(arena.overflow_served() == 0);
	(void)arena.acquire(512, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.initial_served() == 1);
	assert(arena.overflow_served() == 1);
	arena.reset(0);
	assert(arena.initial_served() == 1);
	assert(arena.overflow_served() == 1);
	arena.clear();
	assert(arena.initial_served() == 1);
	assert(arena.overflow_served() == 1);
}

fn void backed_arena_overflow_honors_zero_init() @test
{
	char[8] initial_storage;
	char[512] backing_storage;
	allocators::ArenaAllocator backing_arena;
	backing_arena.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing_arena);

	char* dirty = arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 64; i++) dirty[i] = (char)0xFF;
	arena.release(dirty, false);
	char* clean = arena.acquire(64, alloc::AllocInitType.ZERO)!!;
	for (sz i = 0; i < 64; i++) assert(clean[i] == 0);
}

fn void backed_arena_reset_retaining_parks_and_reuses_pages() @test
{
	char[8] initial_storage;
	char[1024] backing_storage;
	allocators::ArenaAllocator backing_arena;
	backing_arena.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing_arena);

	sz mark = arena.mark();
	(void)arena.acquire(256, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.overflow_count() == 1);
	sz backing_used_live = backing_arena.bytes_reserved();

	arena.reset_retaining(mark);
	assert(arena.overflow_count() == 0);
	assert(arena.page_pool_count() == 1);
	assert(backing_arena.bytes_reserved() == backing_used_live);

	void* reused = arena.acquire(256, alloc::AllocInitType.NO_ZERO)!!;
	assert(reused != null);
	assert(arena.overflow_count() == 1);
	assert(arena.page_pool_count() == 0);
	assert(backing_arena.bytes_reserved() == backing_used_live);
	arena.prune_pool();
	assert(arena.page_pool_count() == 0);
}

fn void backed_arena_reset_retaining_reuses_only_fitting_pages() @test
{
	char[8] initial_storage;
	char[2048] backing_storage;
	allocators::ArenaAllocator backing_arena;
	backing_arena.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing_arena);

	sz mark = arena.mark();
	(void)arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	arena.reset_retaining(mark);
	assert(arena.page_pool_count() == 1);
	sz backing_used = backing_arena.bytes_reserved();

	// A larger request grows the pooled page through the backing allocator
	// instead of allocating a fresh block, because a pooled page holds no
	// live data. The backing arena's reserved bytes grow with the page.
	(void)arena.acquire(512, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.page_pool_count() == 0);
	assert(arena.overflow_count() == 1);
	assert(backing_arena.bytes_reserved() > backing_used);

	// A stricter alignment cannot reuse the default-aligned pooled page.
	arena.reset_retaining(mark);
	assert(arena.page_pool_count() == 1);
	(void)arena.acquire(48, alloc::AllocInitType.NO_ZERO, 64)!!;
	assert(arena.page_pool_count() == 1);
	assert(arena.overflow_count() == 1);
}

fn void backed_arena_free_drains_page_pool() @test
{
	char[8] initial_storage;
	char[512] backing_storage;
	allocators::ArenaAllocator backing_arena;
	backing_arena.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing_arena);

	sz mark = arena.mark();
	(void)arena.acquire(128, alloc::AllocInitType.NO_ZERO)!!;
	arena.reset_retaining(mark);
	assert(arena.page_pool_count() == 1);
	arena.free();
	assert(arena.page_pool_count() == 0);
	assert(arena.overflow_count() == 0);
	assert(backing_arena.bytes_reserved() == 0);
}

fn void backed_arena_owns_covers_both_paths() @test
{
	char[64] initial_storage;
	char[512] backing_storage;
	allocators::ArenaAllocator backing_arena;
	backing_arena.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing_arena);

	void* initial = arena.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	void* overflow = arena.acquire(256, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.owns(initial));
	assert(arena.owns(overflow));
	assert(!arena.owns((char*)initial + 4));
	assert(!arena.owns((void*)0x1));
	arena.release(overflow, false);
	assert(!arena.owns(overflow));
	assert(arena.owns(initial));
}
