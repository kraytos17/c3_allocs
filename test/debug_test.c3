module c3_allocs;

import std::core::mem::alloc;
import c3_allocs::allocators;

fn void freelist_canary_detects_overrun_and_reports_intact() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	char* item = list.acquire(1, alloc::AllocInitType.NO_ZERO)!!;
	assert(list.canary_intact(item));
	item[1] = 0x00; // Overwrite the first canary byte past the requested size.
	assert(!list.canary_intact(item));
	item[1] = 0xC3; // Restore so release does not trip the canary assert.
	assert(list.canary_intact(item));
	list.release(item, false);
}

fn void pool_canary_detects_overrun_and_reports_intact() @test
{
	char[512] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 64);

	char* item = pool.acquire(1, alloc::AllocInitType.NO_ZERO)!!;
	assert(pool.canary_intact(item));
	item[1] = 0x00;
	assert(!pool.canary_intact(item));
	item[1] = 0xC3;
	assert(pool.canary_intact(item));
	pool.release(item, false);
}

fn void buddy_canary_detects_overrun_and_reports_intact() @test
{
	char[512] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	char* item = buddy.acquire(1, alloc::AllocInitType.NO_ZERO)!!;
	assert(buddy.canary_intact(item));
	item[1] = 0x00;
	assert(!buddy.canary_intact(item));
	item[1] = 0xC3;
	assert(buddy.canary_intact(item));
	buddy.release(item, false);
}

fn void backed_arena_canary_detects_overrun_on_overflow_pages() @test
{
	char[8] initial_storage;
	char[512] backing_storage;
	allocators::ArenaAllocator backing_arena;
	backing_arena.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial_storage[..], &backing_arena);

	char* item = arena.acquire(1, alloc::AllocInitType.NO_ZERO)!!;
	assert(arena.canary_intact(item));
	item[1] = 0x00;
	assert(!arena.canary_intact(item));
	item[1] = 0xC3;
	assert(arena.canary_intact(item));
	arena.release(item, false);
}

fn void freelist_resize_recanaries_after_shrink() @test
{
	char[512] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);

	// 9 bytes force block rounding, leaving canary slack past the payload.
	char* item = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	char* shrunk = list.resize(item, 9)!!;
	assert(shrunk == item);
	assert(list.canary_intact(shrunk));
	// Writing past the shrunk size but within the old size must corrupt.
	shrunk[9] = 0x00;
	assert(!list.canary_intact(shrunk));
	shrunk[9] = 0xC3;
	list.release(shrunk, false);
}

fn void buddy_resize_recanaries_after_shrink() @test
{
	char[512] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);

	char* item = buddy.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	char* shrunk = buddy.resize(item, 8)!!;
	assert(shrunk == item);
	assert(buddy.canary_intact(shrunk));
	shrunk[8] = 0x00;
	assert(!buddy.canary_intact(shrunk));
	shrunk[8] = 0xC3;
	buddy.release(shrunk, false);
}

fn void pool_resize_recanaries_after_shrink() @test
{
	char[512] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 64);

	char* item = pool.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	char* shrunk = pool.resize(item, 8)!!;
	assert(shrunk == item);
	assert(pool.canary_intact(shrunk));
	shrunk[8] = 0x00;
	assert(!pool.canary_intact(shrunk));
	shrunk[8] = 0xC3;
	pool.release(shrunk, false);
}
