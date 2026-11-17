module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn void poolchain_spills_across_links_in_order() @test
{
	char[512] first_storage;
	char[512] second_storage;
	char[][2] bufs = { first_storage[..], second_storage[..] };
	allocators::PoolChainAllocator chain;
	chain.init(bufs[..], 64, 16);
	assert(chain.link_count() == 2);
	assert(chain.payload_size() == 64);
	sz per_link = chain.link_capacity(0);
	assert(per_link > 2);
	assert(chain.capacity() == per_link * 2);
	assert(chain.available() == per_link * 2);

	// Fill the first link; the next acquire must spill to the second.
	void*[128] live = { };
	sz live_count = 0;
	for (sz i = 0; i < per_link; i++)
	{
		live[live_count] = chain.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
		live_count++;
	}
	assert(chain.link_available(0) == 0);
	assert(chain.link_available(1) == chain.link_capacity(1));
	void* spilled = chain.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(chain.owns(spilled));
	assert(chain.link_available(1) + 1 == chain.link_capacity(1));
	live[live_count] = spilled;
	live_count++;

	// Release everything; full restore across both links.
	for (sz i = 0; i < live_count; i++) chain.release(live[i], false);
	assert(chain.available() == chain.capacity());
	assert(chain.debug_verify());
}

fn void poolchain_rejects_oversize_and_reports_exhaustion() @test
{
	char[256] first_storage;
	char[256] second_storage;
	char[][2] bufs = { first_storage[..], second_storage[..] };
	allocators::PoolChainAllocator chain;
	chain.init(bufs[..], 32, 0);

	void*? too_big = chain.acquire(33, alloc::AllocInitType.NO_ZERO);
	if (catch too_big)
	{
		// Expected: larger than the configured block size.
	}
	else
	{
		assert(false, "Expected oversize acquire to fail.");
	}

	sz capacity = chain.capacity();
	assert(capacity > 0);
	void*[128] live = { };
	for (sz i = 0; i < capacity; i++) live[i] = chain.acquire(32, alloc::AllocInitType.NO_ZERO)!!;
	assert(chain.available() == 0);
	void*? exhausted = chain.acquire(32, alloc::AllocInitType.NO_ZERO);
	if (catch exhausted)
	{
		// Expected: every link is full.
	}
	else
	{
		assert(false, "Expected acquire on a full chain to fail.");
	}
	for (sz i = 0; i < capacity; i++) chain.release(live[i], false);
	assert(chain.available() == capacity);
}

fn void poolchain_routes_release_resize_and_canary_to_owner() @test
{
	char[512] first_storage;
	char[512] second_storage;
	char[][2] bufs = { first_storage[..], second_storage[..] };
	allocators::PoolChainAllocator chain;
	chain.init(bufs[..], 64, 0);
	sz per_link = chain.link_capacity(0);

	void*[128] live = { };
	sz live_count = 0;
	live[live_count] = chain.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	char* first = live[live_count];
	live_count++;
	for (sz i = 0; i < per_link - 1; i++)
	{
		live[live_count] = chain.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
		live_count++;
	}
	live[live_count] = chain.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	char* spilled = live[live_count];
	live_count++;
	assert(chain.owns(first));
	assert(chain.owns(spilled));
	assert(chain.canary_intact(first));
	assert(chain.canary_intact(spilled));

	char* grown = chain.resize(spilled, 32)!!;
	assert(grown == spilled);
	for (sz i = 16; i < 32; i++) assert(grown[i] == 0xC3);
	assert(chain.canary_intact(grown));

	sz available_before = chain.available();
	char foreign;
	chain.release(&foreign, false);
	assert(chain.available() == available_before);
	chain.release(first, false);
	chain.release(grown, false);
	for (sz i = 0; i < live_count; i++)
	{
		void* p = live[i];
		if (p != first && p != (void*)grown) chain.release(p, false);
	}
	assert(chain.available() == chain.capacity());
}

fn void poolchain_attach_grows_capacity() @test
{
	char[512] first_storage;
	char[512] spare_storage;
	char[][1] bufs = { first_storage[..] };
	allocators::PoolChainAllocator chain;
	chain.init(bufs[..], 64, 0);
	assert(chain.link_count() == 1);
	sz before = chain.capacity();
	assert(before > 0);

	assert(chain.attach(spare_storage[..]));
	assert(chain.link_count() == 2);
	assert(chain.capacity() > before);
	assert(chain.debug_verify());

	// Fill both links, then attach up to the limit; one more fails.
	sz total = chain.capacity();
	void*[256] live = { };
	for (sz i = 0; i < total; i++) live[i] = chain.acquire(64, alloc::AllocInitType.NO_ZERO)!!;
	assert(chain.available() == 0);
	char[64][6] extra;
	for (sz i = 0; i < 6; i++) assert(chain.attach(extra[i][..]));
	assert(chain.link_count() == allocators::POOL_CHAIN_MAX);
	assert(!chain.attach(extra[0][..]));
	for (sz i = 0; i < total; i++) chain.release(live[i], false);
	assert(chain.available() >= total);
}

fn void poolchain_invalid_init_leaves_empty_chain() @test
{
	allocators::PoolChainAllocator chain;
	char[512] storage;
	char[][1] bufs = { storage[..] };
	chain.init(bufs[..], 0, 0);
	assert(chain.link_count() == 0);
	assert(chain.capacity() == 0);
	assert(chain.available() == 0);
	void*? failed = chain.acquire(8, alloc::AllocInitType.NO_ZERO);
	if (catch failed)
	{
		// Expected: no links serve anything.
	}
	else
	{
		assert(false, "Expected acquire on an empty chain to fail.");
	}

	char[][9] too_many = { };
	chain.init(too_many[..], 64, 0);
	assert(chain.link_count() == 0);
}
