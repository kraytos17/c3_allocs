module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import std::thread;
import c3_allocs::allocators;

fn void synchronized_wraps_pool_transparently() @test
{
	char[4096] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 64, 0);
	allocators::SynchronizedAllocator sync;
	sync.init(&pool);
	assert(sync.is_valid());

	char* a = sync.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	char* b = sync.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	assert(a != b);
	for (sz i = 0; i < 32; i++) a[i] = (char)i;
	char* grown = sync.resize(a, 48)!!;
	assert(grown == a);
	for (sz i = 0; i < 32; i++) assert(grown[i] == (char)i);
	sync.release(a, false);
	sync.release(b, false);
	sync.release(b, false);
	sync.release(null, false);
	assert(pool.available() == pool.capacity());
	assert(pool.debug_verify());
	sync.free();
	assert(!sync.is_valid());
}

struct SyncStressWork
{
	allocators::SynchronizedAllocator* sync;
	sz iterations;
}

fn int synchronized_stress_worker(void* raw)
{
	SyncStressWork* work = (SyncStressWork*)raw;
	for (sz i = 0; i < work.iterations; i++)
	{
		void*? got = work.sync.acquire(8 + (sz)(i % 56), alloc::AllocInitType.NO_ZERO);
		if (catch got) continue;
		void* p = got;
		((char*)p)[0] = (char)i;
		work.sync.release(p, false);
	}
	return 0;
}

fn void synchronized_survives_concurrent_use() @test
{
	char[65536] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 64, 0);
	allocators::SynchronizedAllocator sync;
	sync.init(&pool);

	Thread[4] threads;
	SyncStressWork[4] works;
	for (sz i = 0; i < 4; i++)
	{
		works[i] = { .sync = &sync, .iterations = 200 };
		if (catch threads[i].create(&synchronized_stress_worker, &works[i]))
		{
			assert(false, "Failed to spawn stress thread.");
		}
	}
	for (sz i = 0; i < 4; i++) threads[i].join();

	assert(pool.available() == pool.capacity());
	assert(pool.debug_verify());
	sync.free();
}
