module c3_allocs;

import std::core::mem::alloc;
import std::core::mem;
import c3_allocs::allocators;

fn void tracking_counts_and_releases() @test
{
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::TrackingAllocator tracker;
	tracker.init(backing);
	assert(tracker.live_count() == 0);
	assert(tracker.live_bytes() == 0);

	void*? a_opt = allocators::trk_malloc(&tracker, 32);
	if (catch a_opt)
	{
		assert(false, "Expected tracked allocation to succeed.");
	}
	void* a = a_opt;
	assert(tracker.live_count() == 1);
	assert(tracker.live_bytes() == 32);
	assert(tracker.total_count() == 1);

	void*? b_opt = allocators::trk_calloc(&tracker, 16);
	if (catch b_opt)
	{
		assert(false, "Expected tracked calloc to succeed.");
	}
	void* b = b_opt;
	for (sz i = 0; i < 16; i++) assert(((char*)b)[i] == 0);
	assert(tracker.live_count() == 2);
	assert(tracker.live_bytes() == 48);

	allocators::trk_free(&tracker, a);
	assert(tracker.live_count() == 1);
	assert(tracker.live_bytes() == 16);
	assert(tracker.double_releases() == 0);

	allocators::trk_free(&tracker, b);
	assert(tracker.live_count() == 0);
	assert(tracker.live_bytes() == 0);
	assert(tracker.total_count() == 2);
	assert(tracker.check_no_leaks());
	tracker.free();
}

fn void tracking_detects_double_release() @test
{
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::TrackingAllocator tracker;
	tracker.init(backing);

	void*? item_opt = allocators::trk_malloc(&tracker, 24);
	if (catch item_opt)
	{
		assert(false, "Expected tracked allocation to succeed.");
	}
	void* item = item_opt;
	allocators::trk_free(&tracker, item);
	assert(tracker.live_count() == 0);
	allocators::trk_free(&tracker, item);
	assert(tracker.double_releases() == 1);
	assert(tracker.check_no_leaks());
	tracker.free();
}

fn void tracking_realloc_updates_record_and_data() @test
{
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::TrackingAllocator tracker;
	tracker.init(backing);

	void*? data_opt = allocators::trk_malloc(&tracker, 24);
	if (catch data_opt)
	{
		assert(false, "Expected tracked allocation to succeed.");
	}
	char* data = data_opt;
	for (sz i = 0; i < 24; i++) data[i] = (char)(i + 1);

	char*? grown_opt = allocators::trk_realloc(&tracker, data, 48);
	if (catch grown_opt)
	{
		assert(false, "Expected tracked realloc to succeed.");
	}
	char* grown = grown_opt;
	for (sz i = 0; i < 24; i++) assert(grown[i] == (char)(i + 1));
	assert(tracker.live_count() == 1);
	assert(tracker.live_bytes() == 48);

	void*? shrunk_opt = allocators::trk_realloc(&tracker, grown, 8);
	if (catch shrunk_opt)
	{
		assert(false, "Expected tracked shrink to succeed.");
	}
	assert(tracker.live_bytes() == 8);
	allocators::trk_free(&tracker, shrunk_opt);
	assert(tracker.check_no_leaks());
	tracker.free();
}

fn void tracking_reports_leaks_with_sites() @test
{
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::TrackingAllocator tracker;
	tracker.init(backing);

	void*? leak_opt = allocators::trk_malloc(&tracker, 64);
	if (catch leak_opt)
	{
		assert(false, "Expected tracked allocation to succeed.");
	}
	assert(!tracker.check_no_leaks());
	assert(tracker.report_leaks() == 1);
	allocators::trk_free(&tracker, leak_opt);
	assert(tracker.check_no_leaks());
	tracker.free();
}

fn void tracking_wraps_our_own_allocator() @test
{
	char[4096] storage;
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	Allocator backing = &list;
	allocators::TrackingAllocator tracker;
	tracker.init(backing);
	sz initial_free = list.bytes_free();

	void*? first_opt = allocators::trk_malloc(&tracker, 48);
	if (catch first_opt)
	{
		assert(false, "Expected tracked allocation to succeed.");
	}
	void* first = first_opt;
	void* second = allocators::trk_malloc(&tracker, 96)!!;
	assert(list.owns(first));
	assert(list.owns(second));
	allocators::trk_free(&tracker, second);
	allocators::trk_free(&tracker, first);
	assert(tracker.check_no_leaks());
	assert(tracker.double_releases() == 0);
	tracker.free();
	assert(list.bytes_free() == initial_free);
}

fn void tracking_direct_calls_record_unknown_site() @test
{
	Allocator backing = &std::core::mem::allocators::LIBC_ALLOCATOR;
	allocators::TrackingAllocator tracker;
	tracker.init(backing);

	void* item = tracker.acquire(16, alloc::AllocInitType.NO_ZERO)!!;
	assert(tracker.live_count() == 1);
	assert(tracker.total_count() == 1);
	tracker.release(item, false);
	assert(tracker.check_no_leaks());
	tracker.free();
}

fn void tracking_failed_acquire_leaves_no_record() @test
{
	Allocator backing = &std::core::mem::allocators::NULL_ALLOCATOR;
	allocators::TrackingAllocator tracker;
	tracker.init(backing);

	void*? failed = allocators::trk_malloc(&tracker, 32);
	if (catch failed)
	{
		assert(tracker.live_count() == 0);
		assert(tracker.total_count() == 0);
		assert(tracker.check_no_leaks());
		tracker.free();
		return;
	}
	assert(false, "Expected allocation to fail with a null backing allocator.");
}
