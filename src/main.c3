module c3_allocs;

import std::io;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn int main(String[] args)
{
	io::printn("c3_allocs demo");

	char[4096] arena_storage;
	allocators::ArenaAllocator arena;
	arena.init(arena_storage[..]);

	void* arena_item = alloc::malloc(&arena, 128);
	io::printf("arena: capacity=%d reserved=%d\n", arena.capacity(), arena.bytes_reserved());
	alloc::free(&arena, arena_item);
	arena.clear();
	io::printf("arena after clear: reserved=%d\n", arena.bytes_reserved());

	char[4096] pool_storage;
	allocators::PoolAllocator pool;
	pool.init(pool_storage[..], 64, 16);

	void* pool_item = alloc::malloc(&pool, 48);
	io::printf("pool: capacity=%d available=%d\n", pool.capacity(), pool.available());
	alloc::free(&pool, pool_item);
	io::printf("pool after free: available=%d\n", pool.available());

	char[1024] initial_storage;
	char[8192] backing_storage;
	allocators::ArenaAllocator backing;
	backing.init(backing_storage[..]);

	c3_allocs::allocators::BackedArenaAllocator backed;
	backed.init(initial_storage[..], &backing);
	sz backed_mark = backed.mark();

	void* backed_item = alloc::malloc(&backed, 2048);
	io::printf("backed arena: overflow=%d used=%d\n", backed.overflow_count(), backed.bytes_used());
	backed.reset(backed_mark);
	io::printf("backed arena after reset: overflow=%d\n", backed.overflow_count());
	backed.free();

	char[4096] freelist_storage;
	allocators::FreeListAllocator freelist;
	freelist.init(freelist_storage[..]);
	void* list_first = alloc::malloc(&freelist, 48);
	void* list_second = alloc::malloc(&freelist, 96);
	io::printf(
		"freelist: capacity=%d used=%d free=%d\n",
		freelist.capacity(),
		freelist.bytes_used(),
		freelist.bytes_free()
	);

	alloc::free(&freelist, list_first);
	alloc::free(&freelist, list_second);
	freelist.clear();
	io::printf("freelist after clear: free=%d\n", freelist.bytes_free());

	char[512] class_small;
	char[512] class_large;
	char[][2] class_bufs = { class_small[..], class_large[..] };
	sz[2] class_sizes = { 32, 256 };
	allocators::SizeClassAllocator classes;
	classes.init(class_bufs[..], class_sizes[..]);
	void* small = alloc::malloc(&classes, 24);
	io::printf("sizeclass: capacity=%d available=%d\n", classes.capacity(), classes.available());
	alloc::free(&classes, small);

	char[1024] scratch_storage;
	allocators::ScratchAllocator scratch;
	scratch.init(scratch_storage[..]);
	void* tmp = alloc::malloc(&scratch, 64);
	(void)tmp;
	io::printf("scratch: reserved=%d peak=%d\n", scratch.bytes_reserved(), scratch.peak());
	scratch.clear();
	return 0;
}
