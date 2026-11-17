module c3_allocs::bench;

import std::core::mem::alloc;
import c3_allocs::allocators;

const BENCH_BUFFER = 1 << 16;
const BENCH_OPS = 64;

char[BENCH_BUFFER] arena_storage;
char[BENCH_BUFFER] pool_storage;
char[BENCH_BUFFER] freelist_storage;
char[BENCH_BUFFER] buddy_storage;
char[BENCH_BUFFER] bitmap_buddy_storage;
char[BENCH_BUFFER] class_storage;
char[BENCH_BUFFER] scratch_storage;
char[BENCH_BUFFER] backed_initial;
char[BENCH_BUFFER] backed_backing;

fn void bench_arena_acquire_release() @benchmark
{
	allocators::ArenaAllocator arena;
	arena.init(arena_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = arena.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		arena.release(ptr_opt, false);
	}
}

fn void bench_freelist_acquire_release() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(freelist_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = list.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		list.release(ptr_opt, false);
	}
}

fn void bench_freelist_bestfit_acquire_release() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(freelist_storage[..]);
	list.set_policy(allocators::FreeListPolicy.BEST_FIT);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = list.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		list.release(ptr_opt, false);
	}
}

fn void bench_buddy_acquire_release() @benchmark
{
	allocators::BuddyAllocator buddy;
	buddy.init(buddy_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = buddy.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		buddy.release(ptr_opt, false);
	}
}

fn void bench_bitmap_buddy_acquire_release() @benchmark
{
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(bitmap_buddy_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = buddy.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		buddy.release(ptr_opt, false);
	}
}

fn void bench_bitmap_buddy_sixteen_acquire_release() @benchmark
{
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(bitmap_buddy_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = buddy.acquire(16, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		buddy.release(ptr_opt, false);
	}
}

fn void bench_pool_acquire_release() @benchmark
{
	allocators::PoolAllocator pool;
	pool.init(pool_storage[..], 64);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = pool.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		pool.release(ptr_opt, false);
	}
}

fn void bench_sizeclass_acquire_release() @benchmark
{
	char[][8] bufs;
	for (sz i = 0; i < 8; i++) bufs[i] = class_storage[i * (BENCH_BUFFER / 8) : BENCH_BUFFER / 8];
	sz[8] sizes;
	for (sz i = 0; i < 8; i++) sizes[i] = (sz)24 << i;
	allocators::SizeClassAllocator sc;
	sc.init(bufs[0:8], sizes[0:8]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = sc.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		sc.release(ptr_opt, false);
	}
}

fn void bench_arena_clear_cycle() @benchmark
{
	allocators::ArenaAllocator arena;
	arena.init(arena_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}
	arena.clear();
}

fn void bench_buddy_clear_cycle() @benchmark
{
	allocators::BuddyAllocator buddy;
	buddy.init(buddy_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)buddy.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}
	buddy.clear();
}

fn void bench_freelist_clear_cycle() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(freelist_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)list.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}
	list.clear();
}

fn void bench_scratch_clear_cycle() @benchmark
{
	allocators::ScratchAllocator scratch;
	scratch.init(scratch_storage[..]);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)scratch.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}
	scratch.clear();
}

fn void bench_backed_arena_acquire_release() @benchmark
{
	allocators::ArenaAllocator backing;
	backing.init(backed_backing[..]);
	c3_allocs::allocators::BackedArenaAllocator arena;
	arena.init(backed_initial[..], &backing);
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = arena.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		arena.release(ptr_opt, false);
	}
	arena.free();
}

fn void bench_freelist_fragmented_release() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(freelist_storage[..]);
	void*[BENCH_OPS] live = {};
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = list.acquire(128, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		live[i] = ptr_opt;
	}
	for (sz i = 0; i < BENCH_OPS; i += 2) list.release(live[i], false);
	for (sz i = 1; i < BENCH_OPS; i += 2) list.release(live[i], false);
}
