module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import std::core::env;
import c3_allocs::allocators;

fn void hardening_freelist_alignment_torture_16_32_64() @test
{
	char[4096] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	sz[4] sizes = { 1, 7, 24, 100 };
	sz[3] alignments = { 16, 32, 64 };
	void*[12] live = { };
	sz live_count = 0;
	for (sz ai = 0; ai < 3; ai++)
	{
		for (sz si = 0; si < 4; si++)
		{
			char* p = list.acquire(sizes[si], alloc::AllocInitType.NO_ZERO, alignments[ai])!!;
			assert(mem::ptr_is_aligned(p, alignments[ai]));
			for (sz i = 0; i < sizes[si]; i++) p[i] = (char)(i + ai + si);
			assert(list.canary_intact(p));
			live[live_count] = p;
			live_count++;
		}
	}
	assert(list.debug_verify());
	for (sz i = 0; i < live_count; i++) list.release(live[i], false);
	assert(list.bytes_free() == initial_free);
	assert(list.free_block_count() == 1);
	assert(list.debug_verify());
}

fn void hardening_freelist_resize_grows_into_neighbour() @test
{
	char[1024] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	char* a = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 32; i++) a[i] = (char)(i + 1);
	void* b = list.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	list.release(b, false);

	char* grown = list.resize(a, 64, 0)!!;
	assert(grown == a);
	for (sz i = 0; i < 32; i++) assert(grown[i] == (char)(i + 1));
	assert(list.canary_intact(grown));
	assert(list.debug_verify());
	list.release(grown, false);
	assert(list.bytes_free() == initial_free);
	assert(list.free_block_count() == 1);
}

fn void hardening_freelist_corrupt_canary_resize_fails_safely() @test
{
	char[1024] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	// Size 20 leaves a 4-byte canary: the payload offset is 48 and the
	// block rounds up to a multiple of 8.
	char* p = list.acquire(20, alloc::AllocInitType.NO_ZERO)!!;
	for (sz i = 0; i < 20; i++) p[i] = (char)(i + 3);
	assert(list.canary_intact(p));
	p[20] = 0x00;
	assert(!list.canary_intact(p));

	void*? grown = list.resize(p, 24, 0);
	if (catch grown)
	{
		for (sz i = 0; i < 20; i++) assert(p[i] == (char)(i + 3));
	}
	else
	{
		assert(false, "Expected corrupt-canary resize to fail.");
	}

	p[20] = 0xC3;
	assert(list.canary_intact(p));
	list.release(p, false);
	assert(list.bytes_free() == initial_free);
	assert(list.free_block_count() == 1);
}

fn void hardening_freelist_corrupt_canary_release_ignores() @test
{
	char[1024] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	char* p = list.acquire(20, alloc::AllocInitType.NO_ZERO)!!;
	assert(list.canary_intact(p));
	p[20] = 0x00;
	assert(!list.canary_intact(p));

	sz free_before = list.bytes_free();
	sz blocks_before = list.free_block_count();
	list.release(p, false);
	assert(list.bytes_free() == free_before);
	assert(list.free_block_count() == blocks_before);
	assert(list.owns(p));

	p[20] = 0xC3;
	list.release(p, false);
	assert(list.bytes_free() == initial_free);
	assert(list.free_block_count() == 1);
}

fn void hardening_pool_alignment_torture_and_canary_guard() @test
{
	char[2048] storage;
	allocators::PoolAllocator pool;
	pool.init(storage[..], 64, 32);
	sz initial_available = pool.available();

	sz[3] sizes = { 8, 32, 64 };
	void*[3] live = { };
	for (sz i = 0; i < 3; i++)
	{
		char* p = pool.acquire(sizes[i], alloc::AllocInitType.NO_ZERO)!!;
		assert(mem::ptr_is_aligned(p, 32));
		for (sz j = 0; j < sizes[i]; j++) p[j] = (char)(j + i);
		assert(pool.canary_intact(p));
		live[i] = p;
	}

	// A corrupted canary makes release ignore the slot instead of
	// recycling a possibly-overwritten range.
	char* victim = live[0];
	victim[8] = 0x00;
	assert(!pool.canary_intact(victim));
	sz available_before = pool.available();
	pool.release(victim, false);
	assert(pool.available() == available_before);
	victim[8] = 0xC3;
	assert(pool.canary_intact(victim));

	// A corrupted canary fails resize and preserves the block.
	char* target = pool.acquire(20, alloc::AllocInitType.NO_ZERO)!!;
	target[20] = 0x00;
	void*? shrunk = pool.resize(target, 16, 0);
	if (catch shrunk)
	{
		assert(pool.owns(target));
	}
	else
	{
		assert(false, "Expected corrupt-canary pool resize to fail.");
	}
	target[20] = 0xC3;
	pool.release(target, false);

	for (sz i = 0; i < 3; i++) pool.release(live[i], false);
	assert(pool.available() == initial_available);
}

fn void hardening_invalid_init_degrades_safely() @test
{
	// Invalid configurations degrade to inert allocators at every
	// optimization level: guards, not contracts, enforce these.
	char[512] pool_storage;
	allocators::PoolAllocator pool;
	pool.init(pool_storage[..], 0, 0);
	assert(pool.capacity() == 0);
	assert(pool.available() == 0);
	void*? no_slot = pool.acquire(8, alloc::AllocInitType.NO_ZERO);
	if (catch no_slot)
	{
		// Expected: an empty pool serves nothing.
	}
	else
	{
		assert(false, "Expected acquire from an empty pool to fail.");
	}
	assert(!pool.owns(pool_storage[..].ptr));

	pool.init(pool_storage[..], 64, 24);
	assert(pool.capacity() == 0);
	assert(pool.available() == 0);

	// Overflowed slot math must also degrade to an empty pool.
	pool.init(pool_storage[..], sz::max, 0);
	assert(pool.capacity() == 0);
	assert(pool.available() == 0);

	char[128] arena_storage;
	allocators::ArenaAllocator arena;
	arena.init(arena_storage[..]);
	void* first = arena.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	sz reserved_before = arena.bytes_reserved();
	arena.reset(arena.mark() + 100);
	assert(arena.bytes_reserved() == reserved_before);
	assert(arena.owns(first));

	char[64] small_buf;
	char[64] large_buf;
	char[][2] bufs = { small_buf[..], large_buf[..] };
	sz[2] sizes = { 32, 64 };
	allocators::SizeClassAllocator classes;
	classes.init(bufs[..], sizes[..]);
	assert(classes.class_count() == 2);

	char[][1] one_buf = { small_buf[..] };
	sz[2] two_sizes = { 32, 64 };
	allocators::SizeClassAllocator broken;
	broken.init(one_buf[..], two_sizes[..]);
	assert(broken.class_count() == 0);
	void*? no_class = broken.acquire(16, alloc::AllocInitType.NO_ZERO);
	if (catch no_class)
	{
		// Expected: no configured class can serve the request.
	}
	else
	{
		assert(false, "Expected acquire with zero classes to fail.");
	}

	allocators::SizeClassAllocator no_preset;
	char[512] preset_storage;
	no_preset.init_preset(preset_storage[..], 0);
	assert(no_preset.class_count() == 0);
	no_preset.init_preset(preset_storage[..], 100);
	assert(no_preset.class_count() == 0);

	// Out-of-range class queries report zero instead of reading
	// out of bounds.
	assert(classes.class_block_size(-1) == 0);
	assert(classes.class_block_size(99) == 0);
	assert(classes.class_available(-1) == 0);
	assert(classes.class_available(99) == 0);
}
