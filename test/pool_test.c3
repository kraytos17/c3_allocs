module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void pool_allocates_slots_and_reports_capacity() @test
{
	char[512] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 24);

	assert(pool.capacity() > 0);
	assert(pool.available() == pool.capacity());

	void* first = pool.acquire(24, alloc::AllocInitType.NO_ZERO)!!;
	void* second = pool.acquire(1, alloc::AllocInitType.NO_ZERO)!!;
	assert(first != second);
	assert(pool.available() == pool.capacity() - 2);
}

fn void pool_reuses_released_slots() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 16);

	void* first = pool.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	sz free_before = pool.available();
	pool.release(first, false);
	assert(pool.available() == free_before + 1);

	void* reused = pool.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	assert(reused == first);
	assert(pool.available() == free_before);
}

fn void pool_returns_out_of_memory_when_full() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 16);

	sz capacity = pool.capacity();
	for (sz i = 0; i < capacity; i++)
	{
		(void)pool.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	}
	assert(pool.available() == 0);
	sz used_before = pool.available();
	void*? failed = pool.acquire(1, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		assert(pool.available() == used_before);
		return;
	}
	assert(false, "Expected a full pool to report out of memory.");
}

fn void pool_zeroes_requested_bytes() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 32);

	char* bytes = pool.acquire(12, alloc::AllocInitType.ZERO)!!;
	for (sz i = 0; i < 12; i++) assert(bytes[i] == 0);
}

fn void pool_rejects_oversized_and_overaligned_requests() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 16, 16);
	sz free_before = pool.available();

	void*? too_large = pool.acquire(17, alloc::AllocInitType.NO_ZERO);
	if (catch too_large)
	{
		assert(pool.available() == free_before);
	}
	else
	{
		assert(false, "Expected request larger than the pool block to fail.");
	}

	void*? too_aligned = pool.acquire(8, alloc::AllocInitType.NO_ZERO, 64);
	if (catch too_aligned)
	{
		assert(pool.available() == free_before);
		return;
	}
	assert(false, "Expected request above the pool's supported alignment to fail.");
}

fn void pool_resize_updates_requested_size_in_place() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 32);

	char* bytes = pool.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 8; i++) bytes[i] = (char)(i + 1);
	char* grown = pool.resize(bytes, 24)!!;
	assert(grown == bytes);
	for (sz i = 0; i < 8; i++) assert(grown[i] == (char)(i + 1));

	char* shrunk = pool.resize(grown, 4)!!;
	assert(shrunk == bytes);
	for (sz i = 0; i < 4; i++) assert(shrunk[i] == (char)(i + 1));
}

fn void pool_resize_failure_preserves_allocation() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 16);

	char* bytes = pool.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	bytes[0] = 0x5A;
	sz free_before = pool.available();
	void*? failed = pool.resize(bytes, 17);
	if (catch failed)
	{
		assert(pool.available() == free_before);
		assert(bytes[0] == 0x5A);
		return;
	}
	assert(false, "Expected resize larger than a pool slot to fail.");
}

fn void pool_works_with_standard_allocation_helpers() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 32);

	void* bytes = alloc::malloc(&pool, 20);
	assert(bytes != null);
	sz free_after_acquire = pool.available();
	alloc::free(&pool, bytes);
	assert(pool.available() == free_after_acquire + 1);
}

fn void pool_supports_aligned_allocation_helpers() @test
{
	char[512] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 32, 64);

	void* bytes = alloc::malloc_aligned(&pool, 24, 64)!!;
	assert(mem::ptr_is_aligned(bytes, 64));
	alloc::free_aligned(&pool, bytes);
}

fn void pool_ignores_foreign_and_duplicate_releases() @test
{
	char[256] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 16);

	void* bytes = pool.acquire(8, alloc::AllocInitType.NO_ZERO)!!;
	sz available_before = pool.available();
	pool.release(&storage[0], false);
	assert(pool.available() == available_before);

	pool.release(bytes, false);
	sz available_after_release = pool.available();
	pool.release(bytes, false);
	assert(pool.available() == available_after_release);
}
