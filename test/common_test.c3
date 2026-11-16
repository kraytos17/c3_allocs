module c3_allocs;

import std::core::mem;
import c3_allocs::allocators;

fn void common_effective_alignment_floors_to_default() @test
{
	assert(allocators::allocator_effective_alignment(0) == mem::DEFAULT_MEM_ALIGNMENT);
	assert(allocators::allocator_effective_alignment(1) == mem::DEFAULT_MEM_ALIGNMENT);
	assert(allocators::allocator_effective_alignment(64) == 64);
	assert(allocators::allocator_effective_alignment_min(0, 32) == 32);
	assert(allocators::allocator_effective_alignment_min(64, 32) == 64);
}

fn void common_padding_matches_align_up() @test
{
	char[64] storage;
	char[] slice = storage[..];
	uptr base_addr = (uptr)slice.ptr;
	sz padding = allocators::allocator_padding(base_addr, 16);
	assert(padding >= 0 && padding < 16);
	uptr aligned = allocators::allocator_align_up_address(base_addr, 16);
	assert(aligned == base_addr + (uptr)padding);
	assert(allocators::allocator_align_up_size(1, 16) == 16);
	assert(allocators::allocator_align_up_size(16, 16) == 16);
	assert(allocators::allocator_align_up_size(17, 16) == 32);
}

fn void common_grouping_reduces_padding() @test
{
	char[64] storage;
	char[] slice = storage[..];
	uptr base_addr = (uptr)slice.ptr;
	uptr cursor = allocators::allocator_align_up_address(base_addr, 8);
	sz interleaved_waste = 0;
	for (sz i = 0; i < 4; i++)
	{
		uptr u64_addr = allocators::allocator_align_up_address(cursor, 8);
		interleaved_waste += (sz)(u64_addr - cursor);
		cursor = u64_addr + 8;
		uptr u8_addr = allocators::allocator_align_up_address(cursor, 1);
		interleaved_waste += (sz)(u8_addr - cursor);
		cursor = u8_addr + 1;
	}
	cursor = allocators::allocator_align_up_address(base_addr, 8);
	sz grouped_waste = 0;
	for (sz i = 0; i < 4; i++)
	{
		uptr addr = allocators::allocator_align_up_address(cursor, 8);
		grouped_waste += (sz)(addr - cursor);
		cursor = addr + 8;
	}
	for (sz i = 0; i < 4; i++)
	{
		uptr addr = allocators::allocator_align_up_address(cursor, 1);
		grouped_waste += (sz)(addr - cursor);
		cursor = addr + 1;
	}
	assert(grouped_waste <= interleaved_waste);
}

fn void common_checked_add_rejects_overflow() @test
{
	sz sum = 0;
	assert(allocators::allocator_checked_add(10, 20, &sum));
	assert(sum == 30);
	assert(!allocators::allocator_checked_add(sz::max, 1, &sum));
	assert(!allocators::allocator_checked_add(-1, 1, &sum));
}

fn void common_contains_validates_ranges() @test
{
	char[64] storage;
	char[] slice = storage[..];
	uptr base_addr = (uptr)slice.ptr;
	assert(allocators::allocator_contains(base_addr, 64, base_addr, 64));
	assert(allocators::allocator_contains(base_addr, 64, base_addr, 0));
	assert(!allocators::allocator_contains(base_addr, 64, base_addr + 64, 1));
	assert(!allocators::allocator_contains(base_addr, 64, base_addr, 65));
	assert(!allocators::allocator_contains(base_addr, 64, base_addr, -1));
}

fn void common_split_size_avoids_splinters() @test
{
	assert(allocators::allocator_split_size(80, 8, 100, 16) == 80);
	assert(allocators::allocator_split_size(90, 8, 100, 16) == 100);
	assert(allocators::allocator_split_size(200, 8, 100, 16) == 100);
}
