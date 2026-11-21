module c3_allocs::bench;

import std::core::mem::alloc;
import std::thread;
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
char[BENCH_BUFFER] tracking_storage;
char[BENCH_BUFFER] backed_initial;
char[BENCH_BUFFER] backed_backing;
char[BENCH_BUFFER] chain_storage;

fn void bench_arena_acquire_release() @benchmark
{
	allocators::ArenaAllocator arena;
	arena.init(arena_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = arena.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		arena.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_freelist_acquire_release() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(freelist_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = list.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		list.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_freelist_bestfit_acquire_release() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(freelist_storage[..]);
	list.set_policy(allocators::FreeListPolicy.BEST_FIT);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = list.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		list.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_tracking_freelist_acquire_release() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(tracking_storage[..]);
	allocators::TrackingAllocator tracker;
	tracker.init(&list);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = allocators::trk_malloc(&tracker, 64);
		if (catch ptr_opt) return;
		allocators::trk_free(&tracker, ptr_opt);
	}
	@end_benchmark();
	tracker.free();
}

fn void bench_buddy_acquire_release() @benchmark
{
	allocators::BuddyAllocator buddy;
	buddy.init(buddy_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = buddy.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		buddy.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_bitmap_buddy_acquire_release() @benchmark
{
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(bitmap_buddy_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = buddy.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		buddy.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_bitmap_buddy_sixteen_acquire_release() @benchmark
{
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(bitmap_buddy_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = buddy.acquire(16, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		buddy.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_poolchain_acquire_release() @benchmark
{
	char[][2] bufs = { chain_storage[0 : BENCH_BUFFER / 2], chain_storage[BENCH_BUFFER / 2 : BENCH_BUFFER / 2] };
	allocators::PoolChainAllocator chain;
	chain.init(bufs[..], 64);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = chain.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		chain.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_synchronized_acquire_release() @benchmark
{
	allocators::PoolAllocator backing;
	backing.init(pool_storage[..], 64);
	allocators::SynchronizedAllocator sync;
	sync.init(&backing);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = sync.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		sync.release(ptr_opt, false);
	}

	@end_benchmark();
	sync.free();
}

struct BenchSyncWork
{
	allocators::SynchronizedAllocator* sync;
	sz iterations;
}

fn int bench_sync_worker(void* raw)
{
	BenchSyncWork* work = (BenchSyncWork*)raw;
	for (sz i = 0; i < work.iterations; i++)
	{
		void*? ptr_opt = work.sync.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) continue;

		char* p = ptr_opt;
		p[0] = (char)i;
		work.sync.release(p, false);
	}
	return 0;
}

<*
 Contended sharing: four threads hammer one synchronized pool. The
 timed region includes thread spawn and join, so this measures the
 end-to-end cost of sharing, not just the lock itself.
*>
fn void bench_synchronized_contention_acquire_release() @benchmark
{
	allocators::PoolAllocator backing;
	backing.init(pool_storage[..], 64);
	allocators::SynchronizedAllocator sync;
	sync.init(&backing);

	BenchSyncWork[4] works;
	Thread[4] threads;
	@start_benchmark();
	for (sz i = 0; i < 4; i++)
	{
		works[i] = { .sync = &sync, .iterations = BENCH_OPS };
		if (catch threads[i].create(&bench_sync_worker, &works[i])) return;
	}
	for (sz i = 0; i < 4; i++) threads[i].join();

	@end_benchmark();
	sync.free();
}

fn void bench_pool_acquire_release() @benchmark
{
	allocators::PoolAllocator pool;
	pool.init(pool_storage[..], 64);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = pool.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		pool.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_sizeclass_acquire_release() @benchmark
{
	char[][8] bufs;
	for (sz i = 0; i < 8; i++) bufs[i] = class_storage[i * (BENCH_BUFFER / 8) : BENCH_BUFFER / 8];
	sz[8] sizes;
	for (sz i = 0; i < 8; i++) sizes[i] = (sz)24 << i;
	allocators::SizeClassAllocator sc;
	sc.init(bufs[0:8], sizes[0:8]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = sc.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		sc.release(ptr_opt, false);
	}
	@end_benchmark();
}

fn void bench_arena_clear_cycle() @benchmark
{
	allocators::ArenaAllocator arena;
	arena.init(arena_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)arena.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}

	arena.clear();
	@end_benchmark();
}

fn void bench_buddy_clear_cycle() @benchmark
{
	allocators::BuddyAllocator buddy;
	buddy.init(buddy_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)buddy.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}

	buddy.clear();
	@end_benchmark();
}

fn void bench_freelist_clear_cycle() @benchmark
{
	allocators::FreeListAllocator list;
	list.init(freelist_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)list.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}

	list.clear();
	@end_benchmark();
}

fn void bench_scratch_clear_cycle() @benchmark
{
	allocators::ScratchAllocator scratch;
	scratch.init(scratch_storage[..]);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		(void)scratch.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	}

	scratch.clear();
	@end_benchmark();
}

fn void bench_backed_arena_acquire_release() @benchmark
{
	allocators::ArenaAllocator backing;
	backing.init(backed_backing[..]);
	c3_allocs::allocators::BackedArenaAllocator arena;
	arena.init(backed_initial[..], &backing);
	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i++)
	{
		void*? ptr_opt = arena.acquire(64, alloc::AllocInitType.NO_ZERO);
		if (catch ptr_opt) return;
		arena.release(ptr_opt, false);
	}

	@end_benchmark();
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

	@start_benchmark();
	for (sz i = 0; i < BENCH_OPS; i += 2) list.release(live[i], false);
	for (sz i = 1; i < BENCH_OPS; i += 2) list.release(live[i], false);
	@end_benchmark();
}
