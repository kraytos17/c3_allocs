module c3_allocs;

import std::core::mem;
import std::core::mem::alloc;
import c3_allocs::allocators;

const STRESS_MAX_LIVE = 64;

fn ulong stress_next(ulong* state)
{
	*state ^= *state << 13;
	*state ^= *state >> 7;
	*state ^= *state << 17;
	return *state;
}

fn void freelist_pressure_storm_restores_single_range() @test
{
	char[4096] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();

	ulong state = 0x9E3779B97F4A7C15;
	void*[STRESS_MAX_LIVE] live = { };
	sz[STRESS_MAX_LIVE] live_sizes = { };
	sz live_count = 0;

	for (sz op = 0; op < 2000; op++)
	{
		ulong roll = stress_next(&state) % 100;
		if (roll < 55 && live_count < STRESS_MAX_LIVE)
		{
			sz size = 1 + (sz)(stress_next(&state) % 128);
			void*? ptr_opt = list.acquire(size, alloc::AllocInitType.NO_ZERO);
			if (catch ptr_opt) continue;
			live[live_count] = ptr_opt;
			live_sizes[live_count] = size;
			live_count++;
		}
		else if (roll < 90 && live_count > 0)
		{
			ulong roll_index = stress_next(&state);
			sz idx = (sz)(roll_index % (ulong)live_count);
			list.release(live[idx], false);
			live[idx] = live[live_count - 1];
			live_sizes[idx] = live_sizes[live_count - 1];
			live_count--;
		}
		else if (roll < 92 && live_count > 0)
		{
			ulong roll_index = stress_next(&state);
			sz idx = (sz)(roll_index % (ulong)live_count);
			sz new_size = 1 + (sz)(stress_next(&state) % 128);
			void*? resized = list.resize(live[idx], new_size, 0);
			if (catch resized) continue;
			live[idx] = resized;
			live_sizes[idx] = new_size;
		}
		else
		{
			assert(list.bytes_free() <= initial_free);
			assert(list.bytes_used() <= list.capacity());
			assert(list.free_block_count() >= 1 || list.bytes_free() == 0);
		}
	}

	for (sz i = 0; i < live_count; i++) list.release(live[i], false);
	assert(list.bytes_free() == initial_free);
	assert(list.free_block_count() == 1);
	assert(list.largest_free() == initial_free);
}

fn void buddy_pressure_storm_restores_single_block() @test
{
	char[4096] storage;
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	ulong state = 0xA0761D6478BD642F;
	void*[STRESS_MAX_LIVE] live = { };
	sz live_count = 0;

	for (sz op = 0; op < 2000; op++)
	{
		ulong roll = stress_next(&state) % 100;
		if (roll < 55 && live_count < STRESS_MAX_LIVE)
		{
			sz size = 1 + (sz)(stress_next(&state) % 256);
			void*? ptr_opt = buddy.acquire(size, alloc::AllocInitType.NO_ZERO);
			if (catch ptr_opt) continue;
			live[live_count] = ptr_opt;
			live_count++;
		}
		else if (roll < 92 && live_count > 0)
		{
			ulong roll_index = stress_next(&state);
			sz idx = (sz)(roll_index % (ulong)live_count);
			buddy.release(live[idx], false);
			live[idx] = live[live_count - 1];
			live_count--;
		}
		else
		{
			assert(buddy.bytes_free() <= initial_free);
			assert(buddy.free_block_count() >= 1 || buddy.bytes_free() == 0);
		}
	}

	for (sz i = 0; i < live_count; i++) buddy.release(live[i], false);
	assert(buddy.bytes_free() == initial_free);
	assert(buddy.free_block_count() == 1);
	assert(buddy.largest_free() == buddy.capacity());
}

fn void sizeclass_pressure_storm_restores_all_slots() @test
{
	char[512] s0;
	char[512] s1;
	char[512] s2;
	char[][3] bufs = { s0[..], s1[..], s2[..] };
	sz[3] sizes = { 24, 96, 384 };
	allocators::SizeClassAllocator sc;
	sc.init(bufs[..], sizes[..]);
	sz initial_available = sc.available();

	ulong state = 0x2545F4914F6CDD1D;
	void*[STRESS_MAX_LIVE] live = { };
	sz live_count = 0;

	for (sz op = 0; op < 2000; op++)
	{
		ulong roll = stress_next(&state) % 100;
		if (roll < 55 && live_count < STRESS_MAX_LIVE)
		{
			sz size = 1 + (sz)(stress_next(&state) % 384);
			void*? ptr_opt = sc.acquire(size, alloc::AllocInitType.NO_ZERO);
			if (catch ptr_opt) continue;
			live[live_count] = ptr_opt;
			live_count++;
		}
		else if (roll < 92 && live_count > 0)
		{
			ulong roll_index = stress_next(&state);
			sz idx = (sz)(roll_index % (ulong)live_count);
			sc.release(live[idx], false);
			live[idx] = live[live_count - 1];
			live_count--;
		}
		else
		{
			assert(sc.available() <= initial_available);
			assert(sc.available() >= (initial_available - live_count));
		}
	}

	for (sz i = 0; i < live_count; i++) sc.release(live[i], false);
	assert(sc.available() == initial_available);
}

fn void scratch_pressure_storm_tracks_peak_and_clear() @test
{
	char[1024] storage;
	allocators::ScratchAllocator scratch;
	scratch.init(storage[..]);

	ulong state = 0xDEADBEEFCAFEBABE;
	for (sz round = 0; round < 50; round++)
	{
		void*[8] live = { };
		sz live_count = 0;
		for (sz op = 0; op < 40; op++)
		{
			ulong roll = stress_next(&state) % 100;
			if (roll < 60 && live_count < 8)
			{
				void*? ptr_opt = scratch.acquire(1 + (sz)(stress_next(&state) % 64), alloc::AllocInitType.NO_ZERO);
				if (catch ptr_opt) continue;
				live[live_count] = ptr_opt;
				live_count++;
			}
			else if (roll < 95 && live_count > 0)
			{
				scratch.release(live[live_count - 1], false);
				live_count--;
			}
		}
		scratch.clear();
		assert(scratch.bytes_reserved() == 0);
	}
	assert(scratch.peak() > 0);
	assert(scratch.peak() <= scratch.capacity());
}
